#!powershell

# POWERSHELL_COMMON
# WANT_JSON

# complex_args is set by Ansible
$inputArgs = $complex_args

# This is the result object that will be converted to JSON back to Ansible
$result = @{
    changed = $false
    test = $inputArgs.foo
}
ConvertTo-Json -InputObject $result