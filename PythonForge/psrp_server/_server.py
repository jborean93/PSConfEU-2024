# Copyright: (c) 2024 Jordan Borean (@jborean93) <jborean93@gmail.com>
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

from __future__ import annotations

import base64
import collections.abc
import dataclasses
import datetime
import logging
import os
import queue
import socket
import struct
import sys
import textwrap
import threading
import traceback
import typing
import uuid
from xml.etree import ElementTree

import psrpcore

HAS_PSUTIL = True
try:
    import psutil
except ImportError:
    HAS_PSUTIL = False

log = logging.getLogger("psrp_server")


@psrpcore.types.PSType(
    [
        "Microsoft.PowerShell.Commands.WriteErrorException",
        "System.SystemException",
    ]
)
class WriteErrorException(psrpcore.types.NETException):
    def __init__(self, message: str) -> None:
        super().__init__(Message=message, HResult=-2146233087)


class PipeConnection:
    def __init__(self, name: str) -> None:
        self._name = name
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._conn: socket.socket | None = None

    def __enter__(self) -> "PipeConnection":
        if os.name != "nt":
            try:
                os.unlink(self._name)
            except FileNotFoundError:
                pass

        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.bind(self._name)
        self._sock.listen(1)
        self._conn = self._sock.accept()[0]

        return self

    def __exit__(self, *args: typing.Any) -> None:
        if self._conn:
            self._conn.close()
        self._conn = None
        self._sock.close()

    def read(self, length: int) -> bytes:
        conn = self._get_conn()
        return conn.recv(length)

    def send(self, data: bytes) -> None:
        conn = self._get_conn()
        conn.sendall(data)

    def _get_conn(self) -> socket.socket:
        if not self._conn:
            raise Exception("Connection has not been opened")

        return self._conn


class StdioConnection:
    def __enter__(self) -> "StdioConnection":
        return self

    def __exit__(self, *args: typing.Any) -> None:
        pass

    def read(self, length: int) -> bytes:
        return sys.stdin.buffer.readline()

    def send(self, data: bytes) -> None:
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()


class OutOfProcTransport:
    _BUFFER = 32768

    def __init__(
        self,
        conn: PipeConnection | StdioConnection,
    ) -> None:
        super().__init__()
        self.runspace = RunspaceThread(psrpcore.ServerRunspacePool(), self)
        self.pipelines: dict[uuid.UUID, PipelineThread] = {}

        self._conn = conn
        self._event_queue: queue.Queue[psrpcore.PSRPEvent] = queue.Queue()
        self._write_lock = threading.Lock()

    def run(self) -> None:
        log.info(f"Starting connection for {type(self._conn).__name__}")
        self.runspace.start()

        buffer = []
        with self._conn as conn:
            while True:
                data = conn.read(self._BUFFER)
                if not data:
                    log.info("Input pipe has closed")
                    break

                try:
                    end_idx = data.index(b"\n")
                except ValueError:
                    buffer.append(data)
                    continue

                raw_element = b"".join(buffer) + data[:end_idx]
                buffer = [data[end_idx + 1 :]]
                try:
                    self._process(raw_element)

                except Exception as e:
                    log.exception("Unknown exception during message processing")

                    err = psrpcore.types.ErrorRecord(
                        Exception=psrpcore.types.NETException(
                            Message=str(e),
                            StackTrace=traceback.format_exc(),
                        ),
                        CategoryInfo=psrpcore.types.ErrorCategoryInfo(
                            Category=psrpcore.types.ErrorCategory.ReadError,
                            Activity="Parsing PSRP msg",
                            Reason="Unknown result",
                            TargetName=f"RunspacePool({self.runspace.runspace.runspace_pool_id!s})",
                            TargetType=type(self.runspace).__name__,
                        ),
                        FullyQualifiedErrorId="ProcessRunspaceMessageFailure",
                    )
                    if self.runspace.runspace.state in [
                        psrpcore.types.RunspacePoolState.Opened,
                        psrpcore.types.RunspacePoolState.Broken,
                    ]:
                        self.runspace.runspace.set_broken(err)
                        resp = self.runspace.runspace.data_to_send()
                        if resp:
                            self.data(resp)

                    else:
                        raise

                    break

        log.info("Ending PSRP server")

    def close_ack(
        self,
        pipeline_id: uuid.UUID | None = None,
    ) -> None:
        self._write(ps_guid_packet("CloseAck", pipeline_id))

    def command_ack(
        self,
        pipeline_id: uuid.UUID | None = None,
    ) -> None:
        self._write(ps_guid_packet("CommandAck", pipeline_id))

    def data(
        self,
        data: psrpcore.PSRPPayload,
    ) -> None:
        self._write(ps_data_packet(*data))

    def data_ack(
        self,
        pipeline_id: uuid.UUID | None = None,
    ) -> None:
        self._write(ps_guid_packet("DataAck", pipeline_id))

    def signal_ack(
        self,
        pipeline_id: uuid.UUID | None = None,
    ) -> None:
        self._write(ps_guid_packet("SignalAck", pipeline_id))

    def _write(self, data: bytes) -> None:
        with self._write_lock:
            log.debug("Writing %r", data)
            self._conn.send(data)

    def _process(self, data: bytes) -> None:
        log.debug("Processing: %r", data)
        element = ElementTree.fromstring(data)
        ps_guid: uuid.UUID | None = uuid.UUID(element.attrib["PSGuid"])
        if ps_guid == uuid.UUID(int=0):
            ps_guid = None

        log.info("Processing %s [PID %s]", element.tag, ps_guid or "None")

        if element.tag == "Close":
            self._process_close(ps_guid)
            if not ps_guid:
                return

        elif element.tag == "Command":
            self._process_command(ps_guid)

        elif element.tag == "Data":
            self._process_data(element.text, element.attrib.get("Stream", ""), ps_guid)

        elif element.tag == "Signal":
            self._process_signal(ps_guid)

    def _process_close(
        self,
        pipeline_id: uuid.UUID | None = None,
    ) -> None:
        if pipeline_id:
            pipeline = self.pipelines.pop(pipeline_id)
            pipeline.close()
            pipeline.join()

        else:
            self.runspace.close()
            self.runspace.join()

        self.close_ack(pipeline_id)

    def _process_command(
        self,
        pipeline_id: uuid.UUID | None = None,
    ) -> None:
        if pipeline_id:
            pipeline = psrpcore.ServerPipeline(self.runspace.runspace, pipeline_id)
            t = self.pipelines.setdefault(
                pipeline_id, PipelineThread(pipeline, self.runspace, self)
            )
            t.start()
            self.command_ack(pipeline_id)

    def _process_data(
        self,
        data: str | None,
        stream_type: str,
        pipeline_id: uuid.UUID | None = None,
    ) -> None:
        psrp_data = base64.b64decode(data) if data else b""
        st = (
            psrpcore.StreamType.prompt_response
            if stream_type == "PromptResponse"
            else psrpcore.StreamType.default
        )
        self.runspace.runspace.receive_data(
            psrpcore.PSRPPayload(psrp_data, st, pipeline_id)
        )

        while True:
            event = self.runspace.runspace.next_event()
            if not event:
                break

            if pipeline_id:
                self.pipelines[pipeline_id].event_queue.put(event)

            else:
                self.runspace.event_queue.put(event)

        self.data_ack(pipeline_id)

    def _process_signal(
        self,
        pipeline_id: uuid.UUID | None = None,
    ) -> None:
        if pipeline_id:
            pipeline = self.pipelines[pipeline_id]
            pipeline.stop()
            self.signal_ack(pipeline_id)


class RunspaceThread(threading.Thread):
    def __init__(
        self,
        runspace: psrpcore.ServerRunspacePool,
        transport: OutOfProcTransport,
    ) -> None:
        super().__init__(name="runspace")
        self.runspace = runspace
        self.transport = transport
        self.event_queue: queue.Queue[psrpcore.PSRPEvent | None] = queue.Queue()

        self._host_waiter = threading.Condition()
        self._host_result: dict[int, typing.Any] = {}

    def run(self) -> None:
        log.info("Starting runspace thread")

        while True:
            event = self.event_queue.get()
            log.debug("Processing runspace event %r", event)

            if not event:
                with self._host_waiter:
                    self._host_waiter.notify_all()

                break

            if isinstance(event, psrpcore.RunspacePoolHostResponseEvent):
                value = event.error if event.error is not None else event.result
                self._host_result[event.ci] = value
                with self._host_waiter:
                    self._host_waiter.notify_all()

            data = self.runspace.data_to_send()
            if data:
                self.transport.data(data)

        log.info("Ending runspace thread")

    def close(self) -> None:
        self.runspace.close()
        data = self.runspace.data_to_send()
        if data:
            self.transport.data(data)
        self.event_queue.put(None)


class PipelineThread(threading.Thread):
    def __init__(
        self,
        pipeline: psrpcore.ServerPipeline,
        runspace_thread: RunspaceThread,
        transport: OutOfProcTransport,
    ) -> None:
        super().__init__(name=f"pipeline-{pipeline.pipeline_id!s}")
        self.pipeline = pipeline
        self.runspace_thread = runspace_thread
        self.transport = transport
        self.event_queue: queue.Queue[psrpcore.PSRPEvent | None] = queue.Queue()

        self._host_waiter = threading.Condition()
        self._host_result: dict[int, typing.Any] = {}
        self._worker: threading.Thread | None = None

    @property
    def runspace(self) -> psrpcore.ServerRunspacePool:
        return self.pipeline.runspace_pool

    def run(self) -> None:
        log.info("Starting pipeline thread %s", self.pipeline.pipeline_id)

        pipeline_input = []
        pipeline_complete = True
        add_condition = threading.Condition()

        def pipeline_iter() -> collections.abc.Iterable[typing.Any]:
            idx = 0
            while True:
                with add_condition:
                    if idx < len(pipeline_input):
                        value = pipeline_input[idx]
                        idx += 1
                        yield value

                    elif pipeline_complete:
                        break

                    else:
                        add_condition.wait()

        while True:
            event = self.event_queue.get()
            log.debug(
                "Processing pipeline %s event %r", self.pipeline.pipeline_id, event
            )

            if not event:
                pipeline_complete = True
                with add_condition:
                    add_condition.notify_all()

                with self._host_waiter:
                    self._host_waiter.notify_all()

                break

            if isinstance(event, psrpcore.CreatePipelineEvent):
                pipeline_complete = event.pipeline.no_input
                self.start_pwsh_pipeline(
                    event.pipeline,
                    pipeline_iter(),
                )

            elif isinstance(event, psrpcore.PipelineInputEvent):
                with add_condition:
                    pipeline_input.append(event.data)
                    add_condition.notify_all()

            elif isinstance(event, psrpcore.EndOfPipelineInputEvent):
                pipeline_complete = True
                with add_condition:
                    add_condition.notify_all()

            elif isinstance(event, psrpcore.PipelineHostResponseEvent):
                value = event.error if event.error is not None else event.result
                self._host_result[event.ci] = value
                with self._host_waiter:
                    self._host_waiter.notify_all()

            self._send_data()

        log.info("Ending pipeline thread %s", self.pipeline.pipeline_id)

    def start_pwsh_pipeline(
        self,
        info: psrpcore.PowerShell,
        input_data: collections.abc.Iterable[typing.Any],
    ) -> None:
        script = textwrap.dedent(info.commands[0].command_text)
        self._worker = threading.Thread(
            name=f"pipeline-{self.pipeline.pipeline_id!s}-worker",
            target=self._exec,
            args=(script, info.commands[0].parameters, input_data),
        )
        self._worker.start()

    def _exec(
        self,
        code: str,
        raw_parameters: list[tuple[str | None, typing.Any]],
        input_data: collections.abc.Iterable[typing.Any],
    ) -> None:
        try:
            self.pipeline.start()
            _ = self.runspace.data_to_send()

            arguments = []
            parameters = {}
            for raw_name, raw_value in raw_parameters:
                arguments.append(raw_value)

                if raw_name is not None:
                    parameters[raw_name] = raw_value

            ps_host = PSHost(self)

            cmdlet = PSCmdlet(
                _pipeline=self,
                input=input_data,
                host=ps_host,
                args=arguments,
                params=parameters,
            )

            exec_globals = {
                "print": cmdlet.write_host,
                "cmdlet": cmdlet,
            }

            try:
                log.debug("Starting Python code\n%s", code)
                exec(code, exec_globals)
                log.debug("Python code ran successfully")
                self.pipeline.complete()
            except SyntaxError as e:
                log.exception("Attempted to run code with invalid syntax")
                self.pipeline._change_state(
                    psrpcore.types.PSInvocationState.Failed,
                    psrpcore.types.ErrorRecord(
                        Exception=psrpcore.types.NETException(
                            Message=str(e),
                            StackTrace=traceback.format_exc(),
                        ),
                        CategoryInfo=psrpcore.types.ErrorCategoryInfo(
                            Category=psrpcore.types.ErrorCategory.ParserError,
                            Reason="InvalidPythonSyntax",
                        ),
                        FullyQualifiedErrorId="InvalidPythonSyntax",
                    ),
                    emit=True,
                )
            except SystemExit:
                log.debug("Received ctrl+c during exception, attempting to stop code")
                self.pipeline.stop()

            except Exception as e:
                log.exception("Exception when running code")
                self.pipeline.write_error(
                    exception=psrpcore.types.NETException(
                        Message=str(e),
                        StackTrace=traceback.format_exc(),
                    ),
                    category_info=psrpcore.types.ErrorCategoryInfo(
                        Category=psrpcore.types.ErrorCategory.NotSpecified,
                        Reason="UncaughtPythonException",
                    ),
                    fully_qualified_error_id="UncaughtPythonException",
                )
                self.pipeline.complete()

            self._send_data()

        except Exception as e:
            log.exception("Unhandled exception in Python worker thread")

    def close(self) -> None:
        if self.pipeline.state == psrpcore.types.PSInvocationState.Running:
            self.pipeline.begin_stop()

        self.pipeline.close()
        _ = self.runspace.data_to_send()
        self.event_queue.put(None)

    def stop(self) -> None:
        self.pipeline.begin_stop()
        _ = self.runspace.data_to_send()

    def _send_data(self) -> None:
        data = self.runspace.data_to_send()
        if data:
            self.transport.data(data)


@dataclasses.dataclass(frozen=True)
class PSCmdlet:
    _pipeline: PipelineThread = dataclasses.field(repr=False)
    input: collections.abc.Iterable[typing.Any]
    host: PSHost
    args: list[str] = dataclasses.field(default_factory=list)
    params: dict[str, typing.Any] = dataclasses.field(default_factory=dict)

    def write_host(self, msg: str) -> None:
        log.debug("State: %s - Message: %r", self._pipeline.pipeline.state, msg)

        if self._pipeline.pipeline.state == psrpcore.types.PSInvocationState.Stopping:
            sys.exit()

        self.host.write_line(msg)

    def write_output(self, data: typing.Any) -> None:
        log.debug("State: %s - Output: %r", self._pipeline.pipeline.state, data)

        if self._pipeline.pipeline.state == psrpcore.types.PSInvocationState.Stopping:
            sys.exit()

        self._pipeline.pipeline.write_output(data)
        self._pipeline._send_data()

    def write_error(
        self,
        message: str,
        category: psrpcore.types.ErrorCategory = psrpcore.types.ErrorCategory.NotSpecified,
        error_id: str = "Microsoft.PowerShell.Commands.WriteErrorException",
        target_object: typing.Any = None,
        recommended_action: str | None = None,
        category_reason: str = "WriteErrorException",
        category_target_name: str | None = None,
        category_target_type: str | None = None,
    ) -> None:
        log.debug("State: %s - Error: %s", self._pipeline.pipeline.state, message)

        if self._pipeline.pipeline.state == psrpcore.types.PSInvocationState.Stopping:
            sys.exit()

        exception = WriteErrorException(message)

        cat_target_name = None
        cat_target_type = (
            category_target_type if category_target_type is not None else None
        )
        if category_target_name is not None:
            cat_target_name = category_target_name

        if target_object is not None:
            if cat_target_name is None:
                cat_target_name = str(target_object)

            if cat_target_type is None:
                cat_target_type = type(target_object).__name__

        cat_info = psrpcore.types.ErrorCategoryInfo(
            Category=category,
            Activity="Write-Error",
            Reason=category_reason,
            TargetName=cat_target_name,
            TargetType=cat_target_type,
        )
        error_details = None
        if recommended_action:
            error_details = psrpcore.types.ErrorDetails(
                Message=message, RecomendedAction=recommended_action
            )

        self._pipeline.pipeline.write_error(
            exception=exception,
            category_info=cat_info,
            target_object=target_object,
            fully_qualified_error_id=error_id,
            error_details=error_details,
        )
        self._pipeline._send_data()


class PSHost:

    def __init__(
        self,
        pipeline: PipelineThread,
    ) -> None:
        self._pipeline = pipeline

        pipeline_host_info = pipeline.pipeline.metadata.host
        if pipeline_host_info and not pipeline_host_info.UseRunspaceHost:
            log.debug("Using pipeline host info")
            self._host_info = pipeline_host_info
            self._host = psrpcore.ServerHostRequestor(pipeline.pipeline)
            self._waiter = pipeline._host_waiter
            self._result = pipeline._host_result
        else:
            log.debug("Using runspace host info")
            self._host_info = pipeline.runspace.host
            self._host = psrpcore.ServerHostRequestor(pipeline.runspace)
            self._waiter = pipeline.runspace_thread._host_waiter
            self._result = pipeline.runspace_thread._host_result

    def write_line(
        self,
        line: str | None,
        foreground_color: psrpcore.types.ConsoleColor | None = None,
        background_color: psrpcore.types.ConsoleColor | None = None,
    ) -> None:
        self._check_host_present("write_line", "IsHostUINull")

        self._host.write_line(line, foreground_color, background_color)
        self._pipeline._send_data()

    def prompt_for_credential(
        self,
        caption: str,
        message: str,
        username: str | None = None,
        target_name: str | None = None,
        allowed_types: psrpcore.types.PSCredentialTypes | None = None,
        options: psrpcore.types.PSCredentialUIOptions | None = None,
    ) -> psrpcore.types.PSCredential:
        self._check_host_present("prompt_for_credential", "IsHostUINull")

        call_id = self._host.prompt_for_credential(
            caption=caption,
            message=message,
            username=username,
            target_name=target_name,
            allowed_credential_types=allowed_types,
            options=options,
        )
        return self._send_data_with_response(call_id)

    def _check_host_present(
        self,
        method: str,
        host_check: str,
    ) -> None:
        if not self._host_info or getattr(self._host_info, host_check, True):
            raise Exception(f"Host does not support {method}")

    def _send_data_with_response(self, call_id: int) -> typing.Any:
        with self._waiter:
            self._pipeline._send_data()
            log.debug("Waiting for host response %d", call_id)
            self._waiter.wait_for(
                lambda: call_id in self._result
                or self._pipeline.pipeline.state
                != psrpcore.types.PSInvocationState.Running
            )
            log.debug("Call id received for %d", call_id)

        if call_id in self._result:
            result = self._result.pop(call_id)
            log.debug("Received host response for %d: %r", call_id, result)

            if result and isinstance(result, psrpcore.types.ErrorRecord):
                raise Exception(
                    f"Received error from host call: {result.Exception.Message}"
                )

            return result

        sys.exit()


def get_pipe_name() -> str:
    """Gets the default pwsh pipe name for the current process."""
    if not HAS_PSUTIL:
        raise Exception(
            "Using --pipe without a custom pipe name requires the psutil package to be installed."
        )

    pid = os.getpid()
    proc = psutil.Process(pid)
    process_name = proc.name()

    utc_tz = datetime.timezone.utc
    # psutil returns the time as a naive datetime but in the local time. Determining the FileTime from this means it
    # needs to be converted to UTC and then getting the duration since EPOCH.
    ct = datetime.datetime.fromtimestamp(proc.create_time()).astimezone()
    td = ct.astimezone(utc_tz) - datetime.datetime(1970, 1, 1, 0, 0, 0, tzinfo=utc_tz)

    # Number is EPOCH in FileTime format.
    start_time_ft = 116444736000000000 + (
        (td.microseconds + (td.seconds + td.days * 24 * 3600) * 10**6) * 10
    )

    if os.name == "nt":
        start_time = str(start_time_ft)
        pipe_name = (
            f"\\\\.\\pipe\\PSHost.{start_time}.{pid}.DefaultAppDomain.{process_name}"
        )
    else:
        # .NET does `.ToString("X8").Substring(1, 8)`. Using X8 will strip any leading 0's from the hex which is
        # replicated here.
        start_time = (
            base64.b16encode(struct.pack(">Q", start_time_ft)).decode().lstrip("0")[1:9]
        )
        tmpdir = os.environ.get("TMPDIR", "/tmp")
        pipe_name = os.path.join(
            tmpdir, f"CoreFxPipe_PSHost.{start_time}.{pid}.None.{process_name}"
        )

    return pipe_name


def ps_data_packet(
    data: bytes,
    stream_type: psrpcore.StreamType = psrpcore.StreamType.default,
    ps_guid: uuid.UUID | None = None,
) -> bytes:
    """Data packet for PSRP fragments.

    This creates a data packet that is used to encode PSRP fragments when
    sending to the server.

    Args:
        data: The PSRP fragments to encode.
        stream_type: The stream type to target, Default or PromptResponse.
        ps_guid: Set to `None` or a 0'd UUID to target the RunspacePool,
            otherwise this should be the pipeline UUID.

    Returns:
        bytes: The encoded data XML packet.
    """
    ps_guid = ps_guid or uuid.UUID(int=0)
    stream_name = (
        b"Default" if stream_type == psrpcore.StreamType.default else b"PromptResponse"
    )
    return b"<Data Stream='%s' PSGuid='%s'>%s</Data>\n" % (
        stream_name,
        str(ps_guid).lower().encode(),
        base64.b64encode(data),
    )


def ps_guid_packet(
    element: str,
    ps_guid: uuid.UUID | None = None,
) -> bytes:
    """Common PSGuid packet for PSRP message.

    This creates a PSGuid packet that is used to signal events and stages in
    the PSRP exchange. Unlike the data packet this does not contain any PSRP
    fragments.

    Args:
        element: The element type, can be DataAck, Command, CommandAck, Close,
            CloseAck, Signal, and SignalAck.
        ps_guid: Set to `None` or a 0'd UUID to target the RunspacePool,
            otherwise this should be the pipeline UUID.

    Returns:
        bytes: The encoded PSGuid packet.
    """
    ps_guid = ps_guid or uuid.UUID(int=0)
    return b"<%s PSGuid='%s' />\n" % (element.encode(), str(ps_guid).lower().encode())
