# Copyright: (c) 2024, Jordan Borean (@jborean93) <jborean93@gmail.com>
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

$importModule = Get-Command -Name Import-Module -Module Microsoft.PowerShell.Core

$moduleName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
$modPath = [System.IO.Path]::Combine($PSScriptRoot, 'bin', 'Release', 'net7.0', 'publish', "$moduleName.dll")
&$importModule -Name $modPath -ErrorAction Stop -PassThru

enum Destination {
    Client = 0x00000001
    Server = 0x00000002
}

enum MessageType {
    SESSION_CAPABILITY = 0x00010002
    INIT_RUNSPACEPOOL = 0x00010004
    PUBLIC_KEY = 0x00010005
    ENCRYPTED_SESSION_KEY = 0x00010006
    PUBLIC_KEY_REQUEST = 0x00010007
    CONNECT_RUNSPACEPOOL = 0x00010008
    RUNSPACEPOOL_INIT_DATA = 0x0002100B
    RESET_RUNSPACE_STATE = 0x0002100C
    SET_MAX_RUNSPACES = 0x00021002
    SET_MIN_RUNSPACES = 0x00021003
    RUNSPACE_AVAILABILITY = 0x00021004
    RUNSPACEPOOL_STATE = 0x00021005
    CREATE_PIPELINE = 0x00021006
    GET_AVAILABLE_RUNSPACES = 0x00021007
    USER_EVENT = 0x00021008
    APPLICATION_PRIVATE_DATA = 0x00021009
    GET_COMMAND_METADATA = 0x0002100A
    RUNSPACEPOOL_HOST_CALL = 0x00021100
    RUNSPACEPOOL_HOST_RESPONSE = 0x00021101
    PIPELINE_INPUT = 0x00041002
    END_OF_PIPELINE_INPUT = 0x00041003
    PIPELINE_OUTPUT = 0x00041004
    ERROR_RECORD = 0x00041005
    PIPELINE_STATE = 0x00041006
    DEBUG_RECORD = 0x00041007
    VERBOSE_RECORD = 0x00041008
    WARNING_RECORD = 0x00041009
    PROGRESS_RECORD = 0x00041010
    INFORMATION_RECORD = 0x00041011
    PIPELINE_HOST_CALL = 0x00041100
    PIPELINE_HOST_RESPONSE = 0x00041101
}

Function ConvertTo-PSSessionFragment {
    <#
    .SYNOPSIS
    Convert a raw PSRP fragment to an object.

    .PARAMETER InputObject
    The fragment(s) bytes.

    .EXAMPLE
    $rawFragment = [Convert]::FromBase64String($fragmentSource)
    ConvertTo-PSSessionFragment -InputObject $rawFragment

    .OUTPUTS
    PSSession.Fragment
        ObjectID = The unique identifier for a fragmented PSRP message.
        FragmentID = The unique identifier of the fragments in a fragmented PSRP message.
        Start = Whether this is the start PSRP message fragment for the ObjectID (PSRP Message).
        End = Whether this is the last PSRP message fragment for the ObjectID (PSRP Message).
        Blob = The PSRP message fragment bytes.

    .NOTES
    A raw fragment from a PSSession can contain 1, or multiple fragments which this cmdlet will output all of them.
    The structure of this fragment is documented in [MS-PSRP] 2.2.4 Packet Fragment
    https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-psrp/3610dae4-67f7-4175-82da-a3fab83af288.
    #>
    [OutputType('PSSession.Fragment')]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [byte[]]
        $InputObject
    )

    while ($InputObject) {
        # The integer values are in network binary order so we need to reverse the entries.
        [Array]::Reverse($InputObject, 0, 8)
        $objectId = [BitConverter]::ToUInt64($InputObject, 0)

        [Array]::Reverse($InputObject, 8, 8)
        $fragmentId = [BitConverter]::ToUInt64($InputObject, 8)

        $startEndByte = $InputObject[16]
        $start = [bool]($startEndByte -band 0x1)
        $end = [bool]($startEndByte -band 0x2)

        [Array]::Reverse($InputObject, 17, 4)
        $length = [BitConverter]::ToUInt32($InputObject, 17)
        [byte[]]$blob = $InputObject[21..(20 + $length)]

        $InputObject = $InputObject[(21 + $length)..($InputObject.Length)]

        if ($start -and $fragmentId -ne 0) {
            Write-Error -Message "Fragment $objectId start is expecting a fragment ID of 0 but got $fragmentId"
            continue
        }

        [PSCustomObject]@{
            PSTypeName = 'PSSession.Fragment'
            ObjectID = $objectId
            FragmentID = $fragmentId
            Start = $start
            End = $end
            Blob = $blob
        }
    }
}

Function ConvertTo-PSSessionMessage {
    <#
    .SYNOPSIS
    Convert a completed PSRP fragment to a PSRP message object.

    .PARAMETER InputObject
    The completed fragment bytes.

    .PARAMETER ObjectID
    The ObjectID of the fragment(s) the PSRP message belonged to.

    .EXAMPLE
    $rawFragment = [Convert]::FromBase64String($fragmentSource)
    ConvertTo-PSSessionFragment -InputObject $rawFragment | ForEach-Object {
        if ($_.Start -and $_.End) {
            ConvertTo-PSSessionMessage -InputObject $_.Blob -ObjectID $_.ObjectID
        }
    }

    .OUTPUTS
    PSSession.Message
        ObjectID = The unique identifier for the fragment the PSRP message belongs to.
        Destination = The destination of the message
        MessageType = The type of the message.
        RPID = The RunspacePool ID as a GUID the message targets.
        PID = The Pipeline ID as a GUID the message targets.
        Message = The parsed message as a PSObject.
        Raw = The raw CLIXML of the message as a string.

    .NOTES
    The structure of this message is documented in [MS-PSRP] 2.2.1 PowerShell Remoting Protocol Message.
    https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-psrp/497ac440-89fb-4cb3-9cc1-3434c1aa74c3
    #>
    [OutputType('PSSession.Message')]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [byte[]]
        $InputObject,

        [Parameter(Mandatory = $true)]
        [UInt64]
        $ObjectID
    )

    $destination = [Destination][BitConverter]::ToInt32($InputObject, 0)
    $messageType = [MessageType][BitConverter]::ToInt32($InputObject, 4)

    $rpIdBytes = $InputObject[8..23]
    $rpId = [Guid]::new([byte[]]$rpIdBytes)

    $psIdBytes = $InputObject[24..39]
    $psId = [Guid]::new([byte[]]$psIdBytes)

    # Handle if the blob contains the UTF-8 BOM or not.
    $startIdx = 40
    if ($InputObject[40] -eq 239 -and $InputObject[41] -eq 187 -and $InputObject[42] -eq 191) {
        $startIdx = 43
    }
    [byte[]]$dataBytes = $InputObject[$startIdx..$InputObject.Length]
    $message = [Text.Encoding]::UTF8.GetString($dataBytes)

    $clixml = @"
<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04">
$message
</Objs>
"@
    $psObject = [System.Management.Automation.PSSerializer]::Deserialize($clixml)

    # Make our CLIXML pretty with indents so it can be easily parsed by a human
    $stringWriter = [IO.StringWriter]::new()
    $xmlWriter = $null
    try {
        $xmlWriter = [Xml.XmlTextWriter]::new($stringWriter)
        $xmlWriter.Formatting = [Xml.Formatting]::Indented
        $xmlWriter.Indentation = 2
        ([xml]$message).WriteContentTo($xmlWriter)
        $xmlWriter.Flush()
        $stringWriter.Flush()

        $prettyXml = $stringWriter.ToString()
    }
    finally {
        if ($xmlWriter) {
            $xmlWriter.Dispose()
        }
        $stringWriter.Dispose()
    }

    [PSCustomObject]@{
        PSTypeName = 'PSSession.Message'
        ObjectID = $ObjectID
        Destination = $destination
        MessageType = $messageType
        RPID = $rpId
        PID = $psId
        Message = $psObject
        Raw = $prettyXml
    }
}


Function ConvertTo-PSSessionPacket {
    <#
    .SYNOPSIS
    Parse the PSRP packets generated by New-PSSessionLogger into a rich PSObject.

    .PARAMETER InputObject
    The OutOfProc PSRP XML packet to convert.

    .EXAMPLE
    $log = 'C:\temp\pssession.log'
    Remove-Item -Path $log -ErrorAction SilentlyContinue

    $session = New-PSSessionLogger -LogPath $log
    try {
        Invoke-Command -Session $session -ScriptBlock { echo "hi" }
    }
    finally {
        $session | Remove-PSSession
    }
    Get-Content -Path $log | ConvertTo-PSSessionPacket

    .OUTPUTS
    PSSession.Packet
        Type = The OutOfProc XML element type.
        PSGuid = The PSGuid assigned to the packet
        Stream = The stream of the packet (only when Type -eq 'Data')
        Fragments = The fragments contains in the packet (only when Type -eq 'Data')
        Messages = The completed PSRP messages in the fragments (only when Type -eq 'Data')
        Raw = The raw OutOfProc XML value.
    #>
    [OutputType('PSSession.Packet')]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [String[]]
        $InputObject
    )

    begin {
        $fragmentBuffer = @{}
    }

    process {
        foreach ($packet in $InputObject) {
            $xmlData = ([xml]$packet).DocumentElement
            $fragments = $null
            $messages = $null

            if ($xmlData.Name -eq 'Data') {
                $rawFragment = [Convert]::FromBase64String($xmlData.'#text')

                $fragments = ConvertTo-PSSessionFragment -InputObject $rawFragment
                $messages = $fragments | ForEach-Object -Process {
                    if ($_.Start) {
                        $fragmentBuffer.($_.ObjectID) = [Collections.Generic.List[Byte]]@()
                    }

                    $buffer = $fragmentBuffer.($_.ObjectID)
                    $buffer.AddRange($_.Blob)

                    if ($_.End) {
                        $fragmentBuffer.Remove($_.ObjectID)
                        ConvertTo-PSSessionMessage -InputObject $buffer -ObjectID $_.ObjectID
                    }
                }
            }

            [PSCustomObject]@{
                PSTypeName = 'PSSession.Packet'
                Type = $xmlData.Name
                PSGuid = $xmlData.PSGuid
                Stream = $xmlData.Stream
                Fragments = $fragments
                Messages = $messages
                Raw = $packet
            }
        }
    }

    end {
        foreach ($kvp in $fragmentBuffer.GetEnumerator()) {
            Write-Warning -Message "Incomplete buffer for fragment $($kvp.Key)"
        }
    }
}


Function Watch-PSSessionLog {
    <#
    .SYNOPSIS
    Watches a PSSession logging file and outputs parsed PSSession packets as they come in.

    .PARAMETER Path
    The log file to watch.

    .PARAMETER ScanHistory
    Process any existing entries in the log file before waiting for new events.

    .PARAMETER Wait
    Keep on reading the log file even once a session has closed.

    .EXAMPLE
    Watch-PSSessionLog -Path C:\temp\pssession.log
    #>
    [OutputType('PSSession.Packet')]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [String]
        $Path,

        [Switch]
        $ScanHistory,

        [Switch]
        $Wait
    )

    process {
        $gcParams = @{
            LiteralPath = $Path
            Wait = $Wait
        }
        if (-not $ScanHistory) {
            $gcParams.Tail = 0
        }
        Get-Content @gcParams | ConvertTo-PSSessionPacket
    }
}


Function Format-PSSessionPacket {
    <#
    .SYNOPSIS
    Formats a PSSession.Packet to a more human friendly output.

    .PARAMETER InputObject
    The PSSession.Packet object to format.

    .EXAMPLE
    Watch-PSSessionLog -Path C:\temp\pssession.log | Format-PSSessionPacket
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [PSTypeName('PSSession.Packet')]
        $InputObject
    )

    process {
        # The properties are padded to the length of the longest property
        $padding = "Fragments".Length + 1
        $valuePadding = " " * ($padding + 2)
        $formatComplexValue = {
            [CmdletBinding()]
            param (
                [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
                $InputObject,

                [int]
                $PaddingLength = 0
            )
            $padding = " " * $PaddingLength

            # Get the length of the longest property
            $propertyPadding = 0
            foreach ($prop in $InputObject.PSObject.Properties.Name) {
                if ($prop.Length -gt $propertyPadding) {
                    $propertyPadding = $prop.Length
                }
            }

            $sb = [Text.StringBuilder]::new()
            foreach ($prop in $InputObject.PSObject.Properties) {
                $formattedValue = $prop.Value

                if ('System.Management.Automation.PSCustomObject' -in $formattedValue.PSTypeNames) {
                    $formattedValue = @($formattedValue)
                }

                if ($formattedValue -is [Array]) {
                    $formattedValue = foreach ($entry in $formattedValue) {
                        if ($entry -is [PSCustomObject]) {
                            $valuePadding = $propertyPadding + 3
                            $entry = foreach ($subEntry in $entry) {
                                ($subEntry | &$formatComplexValue -PaddingLength $valuePadding).Trim()
                            }

                            $entry = $entry -join "`n"
                        }

                        $entry.Trim()
                    }

                    $formattedValue = $formattedValue -join ("`n`n" + " " * $valuePadding)
                }

                $null = $sb.
                Append($padding).
                Append($prop.Name).
                Append(" " * ($propertyPadding - $prop.Name.Length)).
                Append(" : $formattedValue`n")
            }

            $sb.ToString()
        }

        $obj = $InputObject | Select-Object -Property @(
            'Type',
            @{ N = 'PSGuid'; E = { $_.PSGuid.ToString() } },
            'Stream',
            @{
                N = 'Fragments'
                E = {
                    @($_.Fragments | Select-Object -Property @(
                            'ObjectID',
                            'FragmentID',
                            'Start',
                            'End',
                            @{ N = 'Length'; E = { $_.Blob.Length } }
                        ))
                }
            },
            @{
                N = 'Messages'
                E = {
                    @($_.Messages | Select-Object -Property @(
                            'ObjectID',
                            'Destination',
                            'MessageType',
                            @{ N = 'RPID'; E = { $_.RPID.ToString() } },
                            @{ N = 'PID'; E = { $_.PID.ToString() } },
                            @{ N = 'Object'; E = {
                                    if ($_.MessageType -eq 'RUNSPACEPOOL_STATE') {
                                        $state = [Enum]::GetName([System.Management.Automation.Runspaces.RunspacePoolState], $_.Message.RunspaceState)
                                        if (-not $state) {
                                            $state = 'Unknown'
                                        }
                                        "State: $state`n$($_.Raw)"
                                    }
                                    elseif ($_.MessageType -eq 'PIPELINE_STATE') {
                                        $state = [Enum]::GetName([System.Management.Automation.PSInvocationState], $_.Message.PipelineState)
                                        if (-not $state) {
                                            $state = 'Unknown'
                                        }
                                        "State: $state`n$($_.Raw)"
                                    }
                                    else {
                                        "`n$($_.Raw)"
                                    }
                                }
                            }
                        ))
                }
            }
        )

        $msg = $obj | &$formatComplexValue
        Write-Host $msg
    }
}

Export-ModuleMember -Function 'ConvertTo-PSSessionPacket', 'Watch-PSSessionLog', 'Format-PSSessionPacket'