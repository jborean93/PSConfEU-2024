#!powershell

#AnsibleRequires -CSharpUtil Ansible.Basic

$spec = @{
    options = @{
        bool = @{ type = 'bool' }
        dict = @{ type = 'dict' }
        dict_options = @{
            type = 'dict'
            options = @{
                int = @{ type = 'int' }
                bool = @{ type = 'bool' }
            }
        }
        float = @{ type = 'float' }
        int = @{ type = 'int' }
        json = @{ type = 'json' }
        list = @{ type = 'list' }
        list_elements = @{
            type = 'list'
            elements = 'int'
        }
        list_of_dicts = @{
            type = 'list'
            elements = 'dict'
            options = @{
                int = @{ type = 'int' }
                bool = @{ type = 'bool' }
            }
        }
        path = @{ type = 'path' }
        raw = @{ type = 'raw' }
        sid = @{ type = 'sid' }
        str = @{ type = 'str' }
    }
}
$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)

$module.ExitJson()
