#!powershell

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -CSharpUtil ..module_utils.CSharp
#AnsibleRequires -PowerShell ..module_utils.PowerShell

$spec = @{
    options = @{}
}
$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)

$module.Result.pwsh = Get-PowerShellModuleInfo
# $module.Result.csharp = [Pwsh.Conf.CSharp.Utils]::GetCSharpInfo()
# $module.Result.csharp = [ansible_collections.pwsh.conf.plugins.module_utils.CSharp.Utils]::GetCSharpInfo()

$module.ExitJson()
