#!powershell

#AnsibleRequires -CSharpUtil Ansible.Basic

$spec = @{
    options = @{
        # Option can be referenced through aliases or alias_one
        aliases = @{
            aliases = 'alias_one'
        }
        # Option can only be set to foo, bar, or unset
        choices = @{
            choices = 'foo', 'bar'
        }
        # Option defaults to foo and not $null
        default = @{
            default = 'foo'
        }
        # Option will not report it's invocation
        no_log = @{
            no_log = $true
        }
        # Option is required, will fail
        required = @{
            required = $true
        }

        exclusive_set_1 = @{ type = 'str' }
        exclusive_set_2 = @{ type = 'str' }
        exclusive_set_3 = @{ type = 'str' }

        option_that_requires = @{ type = 'str' }
        option_required_by_1 = @{ type = 'str' }
        option_required_by_2 = @{ type = 'str' }

        required_if_option = @{ type = 'str' }
        required_if_option_1 = @{ type = 'str' }
        required_if_option_2 = @{ type = 'str' }

        required_one_of_1 = @{ type= 'str' }
        required_one_of_2 = @{ type = 'str' }

        required_together_1 = @{ type = 'str' }
        required_together_2 = @{ type = 'str' }
    }

    # Values in each set cannot be set together
    # Good when you have conflicting identifiers that cannot be used together
    mutually_exclusive = @(
        , @('exclusive_set_1', 'exclusive_set_2', 'exclusive_set_3')
    )
    # Options in the value must be set if the key is also set
    # Good when
    required_by = @{
        option_that_requires = @('option_required_by_1', 'option_required_by_2')
    }
    # If required_if_option is set to value1, then these options must be set
    # Good when dealing with state=present/absent specific options.
    required_if = @(
        , @('required_if_option', 'value1', @('required_if_option_1', 'required_if_option_2'))
    )
    # One of the values must be defined
    # Good when managing a resource that can be identified by different ids, path/name/thumbprint
    required_one_of = @(
        , @('required_one_of_1', 'required_one_of_2')
    )
    # If either is set, the other(s) must be. Good for username/password type options
    required_together = @(
        , @('required_together_1', 'required_together_2')
    )
}
$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)

$module.ExitJson()
