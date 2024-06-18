<#
Commands that use PSRemoting

Run this to startup test SSH server

$targetModuleDir = "/home/testuser/.local/share/powershell/Modules"
$forgeBase = Split-Path -Parent (Import-Module -Name RemoteForge -PassThru).ModuleBase
$sudoBase = Split-Path -Parent (Import-Module -Name SudoForge -PassThru).ModuleBase
podman run --rm  --detach -p 8022:22 -v ${forgeBase}:$targetModuleDir/RemoteForge -v ${sudoBase}:$targetModuleDir/SudoForge psremoting
#>

# Non-interactive remoting
Invoke-Command -HostName server2025.domain.test { 'foo' }

# Interactive remoting
Enter-PSSession -HostName server2025.domain.test
Enter-PSSession -ComputerName server2025.domain.test
Enter-PSHostProcess -Id ...

# Shows the named pipes/UDS on *nix
$pid
Get-ChildItem -Path "$([System.IO.Path]::GetTempPath())/CoreFXPipe_PSHost*" -Name

# Shows the named pipes on Windows
Enter-PSSession -HostName server2025.domain.test
$pid
Get-ChildItem -Path "\\.\pipe\" -Name | ? { $_.StartsWith("PSHost.") }
exit

# Creating a long lived session
$s = New-PSSession -HostName server2025.domain.test
Invoke-Command -Session $s { $foo = 'abc' }
Invoke-Command -Session $s { $foo }
$s | Remove-PSSession

<#
Can also use the .NET API
#>
$connInfo = [System.Management.Automation.Runspaces.SSHConnectionInfo]::new("vagrant-domain@DOMAIN.TEST", "server2025.domain.test", $null)
$runspace = [runspacefactory]::CreateRunspace($connInfo)
$runspace.Open()
$ps = [PowerShell]::Create($runspace)
$ps.AddScript('hostname').Invoke()
$runspace.Dispose()

<#
They output are objects, yet they are serialized
#>
$out = Invoke-Command -HostName server2025.domain.test {
    "string value"
    Get-Service -Name sshd
    [PSCustomObject]@{
        Foo = 'bar'
    }
}

<#
How it works
#>
Import-Module -Name ./LoggingForge/LoggingForge.psd1
$s = New-RemoteForgeSession Logging:/tmp/psremoting.log

Watch-PSSessionLog -Path /tmp/psremoting.log -Wait | Format-PSSessionPacket

Invoke-Command -Session $s { $args[0] } -ArgumentList 'foo'
$out = Invoke-Command -Session $s { Get-Credential }
$out
$out.GetNetworkCredential().Password

$s | Remove-PSSession

<#
Transport types
#>
# WSManConnectionInfo
Invoke-Command -ComputerName server2025.domain.test { 'foo' }

# SSHConnectionInfo
Invoke-Command -HostName server2025.domain.test { 'foo' }

# VMConnectionInfo
Invoke-Command -VMName ... { 'foo' }
Invoke-Command -VMId ... { 'foo' }

# ContainerConnectionInfo
Invoke-Command -ContainerId ... { 'foo' }

# NamedPipeConnectionInfo
Enter-PSHostProcess ...

$s = New-PSSession -UseWindowsPowerShell
Invoke-Command -Session $s { 'foo' }
$s | Remove-PSSession

Start-Job -ScriptBlock { 'foo' } | Receive-Job -Wait -AutoRemoveJob

<#
Custom transports - RemoteForge
https://github.com/jborean93/RemoteForge
#>

Get-RemoteForge

# Shims for the builtin transport ssh/winrm
Invoke-Remote ssh:server2025.domain.test { hostname }
Invoke-Remote wsman:server2025.domain.test { hostname }

# Custom SSH transport
Import-Module -Name SSHForge
Get-RemoteForge

Invoke-Remote TmdsSsh:vagrant-domain@DOMAIN.TEST@server2025.domain.test { whoami }

# Builtin command has limitations for SSH, no -Credential, complex way to skip host checking
Invoke-Command -HostName testuser@localhost:8022 { whoami }
Invoke-Command -HostName testuser@localhost:8022 -Options @{
    StrictHostKeyChecking = 'no'
    UserKnownHostsFile = '/dev/null'
} { whoami }

# With a custom transport we can wrap all this in a friendly API
$cred = Get-Credential testuser
$connInfo = New-TmdsSshConnectionInfo -HostName localhost -Port 8022 -Credential $cred -SkipHostKeyCheck
Invoke-Remote $connInfo { whoami }

# We can even get a powershell friendly credentialy prompter
# Edit ~/.ssh/config to edit out our default user/kerb options
Invoke-Remote vagrant-domain@DOMAIN.TEST@server2025.domain.test { whoami }

# To demonstrate the tty differences
ssh -o User=testuser -o Port=8022 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null localhost
sudo whoami

Enter-Remote (New-TmdsSshInfo -ComputerName localhost -Port 8022 -SkipHostKeyCheck -Credential $cred)
sudo whoami

# FIXME: Stop it hanging
Import-Module SudoForge
Invoke-Remote sudo: { whoami }

# Can even work with an explicitly provided credential
Invoke-Remote (New-SudoForgeInfo -Credential $cred) { whoami }

# You can even extend it to other language like Python!
Import-Module ./PythonForge
Invoke-Remote Python: @'
cmdlet.write_output("foo")
'@

1, 2, 3 | Invoke-Remote Python: @'
for value in cmdlet.input:
    print(value)
'@