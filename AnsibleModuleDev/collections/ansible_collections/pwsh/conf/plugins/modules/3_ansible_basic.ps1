#!powershell

#AnsibleRequires -CSharpUtil Ansible.Basic

# Defines the module arguments
$spec = @{
    options = @{
        foo = @{ type = 'int'; required = $true }
    }
}
$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)

# Sets return values to give back to Ansible
$module.Result.test = $module.Params.foo

if ($module.Params.foo -eq 3) {
    $module.FailJson("This is an error message that reports a failure")
}

# Called to exit the module and return the data to Ansible
$module.ExitJson()
