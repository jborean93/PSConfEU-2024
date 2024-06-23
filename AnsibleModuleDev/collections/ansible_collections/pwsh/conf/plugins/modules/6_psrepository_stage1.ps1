#!powershell

#AnsibleRequires -CSharpUtil Ansible.Basic

$spec = @{
    options = @{
        name = @{ type = 'str'; required = $true }
        state = @{ type = 'str'; choices = 'absent', 'present'; default = 'present' }
        url = @{ type = 'str' }
    }
    required_if = @(
        , @('state', 'present', @('url'))
    )
}
$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)

$name = $module.Params.name
$state = $module.Params.state
$url = $module.Params.url

$repository = Get-PSResourceRepository -Name $name -ErrorAction SilentlyContinue

if ($state -eq 'absent') {
    if ($repository) {
        Unregister-PSResourceRepository -Name $name
        $module.Result.changed = $true
    }
}
elseif ($state -eq 'present') {
    if ($repository) {
        $changeParams = @{}

        if ($repository.Uri -ne $url) {
            $changeParams.Uri = $url
        }

        if ($changeParams.Count) {
            Set-PSResourceRepository -Name $name @changeParams
            $module.Result.changed = $true
        }
    }
    else {
        Register-PSResourceRepository -Name $name -Uri $url -Force
        $module.Result.changed = $true
    }
}

$module.ExitJson()
