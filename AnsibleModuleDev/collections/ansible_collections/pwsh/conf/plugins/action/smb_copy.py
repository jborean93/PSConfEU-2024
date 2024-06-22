from __future__ import annotations

import hashlib
import pathlib
import typing as t

from ansible.plugins.action import ActionBase
from ansible.utils.hashing import checksum

HAS_SMBPROTOCOL = True
try:
    import smbclient
    import smbclient.shutil
except ImportError:
    HAS_SMBPROTOCOL = False


class ActionModule(ActionBase):

    _VALID_ARGS = [
        'src',
        'dest'
    ]

    def run(self, tmp: str | None = None, task_vars: dict[str, t.Any] | None = None):
        if task_vars is None:
            task_vars = dict()

        result = super(ActionModule, self).run(tmp, task_vars)
        del tmp  # tmp no longer has any effect

        if not HAS_SMBPROTOCOL:
            result['failed'] = True
            result['msg'] = "This plugin requires the smbprotocol library to be installed."
            return result

        source = self._task.args.get('src', None)
        dest = self._task.args.get('dest', None)

        if not source or not dest:
            result['failed'] = True
            result['msg'] = "The src and dest options must be set"

        source_path = pathlib.Path(source)
        if not source_path.exists() or source_path.is_dir():
            result['failed'] = True
            result['msg'] = "The src file does not exist"

        stat_res = self._execute_module(
            module_name="ansible.windows.win_stat",
            module_args={
                "checksum_algorithm": "sha256",
                "get_checksum": True,
                "get_size": True,
                "path": dest,
            },
            task_vars=task_vars,
        )

        if stat_res.get("failed", False):
            result['failed'] = True
            result['msg'] = f"Failed to get stat of remote file: {stat_res.get('msg', 'Unknown failure')}"
            return result

        if stat_res["stat"].get("exists", True):
            local_checksum = checksum(str(source_path.absolute()), hashlib.sha256)

            if local_checksum.lower() == stat_res["stat"].get("checksum", "").lower():
                return result

        result['changed'] = True

        remote_addr = self._connection.get_option('remote_addr')
        remote_user = self._connection.get_option('remote_user')
        remote_pass = self._connection.get_option('remote_password')

        unc_path = f"\\\\{remote_addr}\\c$\\Windows\\Temp\\pwsh.conf.smb_copy"
        with smbclient.open_file(unc_path, username=remote_user, password=remote_pass, mode="wb") as dst_fd:
            with open(source_path, mode="rb") as src_fd:
                smbclient.shutil.copyfileobj(src_fd, dst_fd)

        try:
            copy_res = self._execute_module(
                module_name="ansible.windows.win_copy",
                module_args={
                    "dest": dest,
                    "src": r"C:\Windows\Temp\pwsh.conf.smb_copy",
                    "_original_basename": source_path.name,
                    "_copy_mode": "single",
                },
                task_vars=task_vars,
            )

        finally:
            smbclient.remove(unc_path)

        return copy_res
