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
    supports_check_mode = $true
}
$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)

$name = $module.Params.name
$state = $module.Params.state
$url = $module.Params.url

$module.Diff.before = $null
$module.Diff.after = $null

$repository = Get-PSResourceRepository -Name $name -ErrorAction SilentlyContinue

if ($repository) {
    $module.Diff.before = @{
        name = $repository.Name
        url = $repository.Uri
    }
}

if ($state -eq 'absent' -and $repository) {
    Unregister-PSResourceRepository -Name $name -WhatIf:$module.CheckMode
    $module.Result.changed = $true
}
elseif ($state -eq 'present') {
    if ($repository) {
        $changeParams = @{}
        $module.Diff.after = $module.Diff.before.Clone()

        if ($repository.Uri -ne $url) {
            $changeParams.Uri = $url
            $module.Diff.after.url = $url
        }

        if ($changeParams.Count) {
            Set-PSResourceRepository -Name $name @changeParams -WhatIf:$module.CheckMode
            $module.Result.changed = $true
        }
    }
    else {
        $module.Diff.after = @{
            name = $name
            url = $url
        }
        Register-PSResourceRepository -Name $name -Uri $url -Force -WhatIf:$module.CheckMode
        $module.Result.changed = $true
    }
}

$module.ExitJson()
