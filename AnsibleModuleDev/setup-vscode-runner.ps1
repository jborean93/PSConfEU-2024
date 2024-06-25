$devPath = Join-Path $pwd.Path 'PSConfEU'
if (-not (Test-Path -LiteralPath $devPath)) {
    New-Item -Path $devPath -ItemType Directory -Force | Out-Null
}

& {
    $ProgressPreference = 'SilentlyContinue'
    $ansibleUrl = 'http://github.com/ansible/ansible/archive/stable-2.17.zip'
    Invoke-WebRequest -Uri $ansibleUrl -OutFile $devPath/ansible.zip
    Expand-Archive -LiteralPath $devPath/ansible.zip -DestinationPath $devPath
}

Remove-Item -LiteralPath $devPath/ansible.zip -Force
Move-Item -LiteralPath $devPath/ansible-stable-2.17 -Destination $devPath/ansible


Set-Content -LiteralPath $devPath/run.ps1 -Value @'
param (
    [Parameter(Mandatory, Position = 0)]
    [string]
    $Module
)

$ErrorActionPreference = "Stop"

$execWrapperPath = "$PSScriptRoot\ansible\lib\ansible\executor\powershell\exec_wrapper.ps1"
$execWrapperAst = [System.Management.Automation.Language.Parser]::ParseFile($execWrapperPath, [ref]$null, [ref]$null)
$commonFunctions = $execWrapperAst.FindAll({
    $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] `
        -and $args[0].VariablePath.UserPath -eq 'script:common_functions'
}, $true)
. $commonFunctions.Parent.Right.Expression.ScriptBlock.GetScriptBlock()
Remove-Variable -Name execWrapperPath
Remove-Variable -Name execWrapperAst
Remove-Variable -Name commonFunctions

$complex_args = ConvertFrom-AnsibleJson (Get-Content "$PSScriptRoot\$Module.json" -Raw)
$complex_args._ansible_module_name = $Module
if (-not $complex_args.ContainsKey('_ansible_check_mode')) {
    $complex_args._ansible_check_mode = $false
}
if (-not $complex_args.ContainsKey('_ansible_diff')) {
    $complex_args._ansible_diff = $false
}

Import-Module -Name "$PSScriptRoot\ansible\lib\ansible\module_utils\powershell\Ansible.ModuleUtils.AddType.psm1"
Add-CSharpType -References @(
    [System.IO.File]::ReadAllText("$PSScriptRoot\ansible\lib\ansible\module_utils\csharp\Ansible.Basic.cs")
) -IncludeDebugInfo

& "$PSScriptRoot\$Module.ps1"
'@

$vsCodeFolder = Join-Path $devPath '.vscode'
if (-not (Test-Path -LiteralPath $vsCodeFolder)) {
    New-Item -Path $vsCodeFolder -ItemType Directory
}
Set-Content -LiteralPath $vsCodeFolder/launch.json @'
{
    "configurations": [
        {
            "name": "Run Ansible Module",
            "type": "PowerShell",
            "request": "launch",
            "script": "${workspaceFolder}/run.ps1",
            "args": [
                "${fileBasenameNoExtension}"
            ],
            "cwd": "${cwd}"
        }
    ]
}
'@
