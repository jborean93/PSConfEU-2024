#!powershell

#AnsibleRequires -CSharpUtil Ansible.Basic

$spec = @{
    options = @{}
}
$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)

$module.ExitJson()
