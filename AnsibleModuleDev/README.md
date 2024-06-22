# Ansible Module Development for Windows
This is a demo that goes through development of Windows modules for Ansible.

## Requirements

+ Linux or macOS environment to run Ansible from
+ Windows host to target

If you only have a Windows environment, the simplest way to run Ansible would be to do it from WSL.

## Setup
The first step is to install Ansible on the Linux or macOS environment.
I find the best way to do this is to use a Python virtual environment as it isolates the dependencies into a single package and won't impact the global environment.
The following steps will create a virtual environment called `psconfeu` in the current directory, activate that environment, then install the Python dependencies used in this demo (Ansible, pypsrp, smbprotocol).

```bash
python3 -m venv psconfeu
source psconfeu/bin/activate
pip install -r requirements.txt
```

Otherwise you can install as per the Ansible documentation https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html.

Once installed you should be able to run the following to verify Ansible works and install the base-line Windows collection:

```bash
ansible --version
ansible-galaxy collection install ansible.windows -p collections --force
```

Once Ansible is running create a copy of `inventory.template` and call the file `inventory`.
Fill in the hostname, username, and password for the target Windows host.
If targeting the local Windows host use `localhost` with the username/password filled out.
On the target Windows host make sure that WinRM and PSRemoting has been setup.

```powershell
winrm quickconfig -q
Enable-PSRemoting -Force
```

Running the following should show `Transport = HTTP` and `Port = 5985`.

```powershell
winrm e winrm/config/listener

# Listener
#     Address = *
#     Transport = HTTP
#     Port = 5985
#     Hostname
#     Enabled = true
#     URLPrefix = wsman
#     CertificateThumbprint
#     ListeningOn = ...
```

Once Ansible and WinRM has been configured we should be able to run `ansible windows -m ansible.windows.win_ping` to verify everything is set up and working.

```
win-host | SUCCESS =>
    changed: false
    ping: pong
```

## Examples

### 1. Basic PowerShell Module
Very basic example that outputs raw JSON back to Ansible:

```bash
ansible windows --playbook-dir . -m pwsh.conf.1_simple

win-host | SUCCESS =>
    changed: false
    key: some return value
    msg: foo
```

### 2. Providing Data to a module
Can be used to get input value from Ansible:

```bash
ansible windows --playbook-dir . -m pwsh.conf.2_args -a foo=bar
win-host | SUCCESS =>
    changed: false
    test: bar
```

### 3. Ansible.Basic
Recommended way to build modules is through Ansible.Basic

```bash
ansible windows --playbook-dir . -m pwsh.conf.3_ansible_basic -a foo=1

win-host | SUCCESS =>
    changed: false
    test: 1

ansible windows --playbook-dir . -m pwsh.conf.3_ansible_basic -a foo=2 -vvv

win-host | SUCCESS =>
    changed: false
    invocation:
        module_args:
            foo: 2
    test: 2

ansible windows --playbook-dir . -m pwsh.conf.3_ansible_basic

win-host | FAILED! =>
    changed: false
    msg: 'missing required arguments: foo'

ansible windows --playbook-dir . -m pwsh.conf.3_ansible_basic -a foo=invalid

win-host | FAILED! =>
    changed: false
    msg: 'argument for foo is of type System.String and we were unable to convert to int:
        Input string was not in a correct format.'
```

We can also see the effects of `FailJson($msg)` to provide error details back to the caller:

```bash
ansible windows --playbook-dir . -m pwsh.conf.3_ansible_basic -a foo=3

win-host | FAILED! =>
    changed: false
    msg: This is an error message that reports a failure
    test: 3
```

### 4. Options
Each module option has a few builtin feature that can control how it is validated and used.
Common controls are for things like making it mandatory, setting specific choices, marking it as sensitive and defining options and how they relate to each other.

```bash
ansible-playbook 4_options.yml -vvv

ok: [win-host] =>
    changed: false
    invocation:
        module_args:
            alias_one: foo
            aliases: foo
            choices: bar
            default: foo
            exclusive_set_1: null
            exclusive_set_2: set
            exclusive_set_3: null
            no_log: VALUE_SPECIFIED_IN_NO_LOG_PARAMETER
            option_required_by_1: set
            option_required_by_2: set
            option_that_requires: set
            required: This is set
            required_if_option: value1
            required_if_option_1: set
            required_if_option_2: set
            required_one_of_1: set
            required_one_of_2: null
            required_together_1: set
            required_together_2: set
```

### 5. Option Types
You can define more complex argument specs supporting types like `bool`, `str`, `int`, `list`, `dict` as well as nested options.
You can also define rules like mutually exclusive options, options that are required together and so on.
By running the playbook `5_option_types.yml` we can see this in action:

```bash
ansible-playbook 5_option_types.yml -vvv

ok: [win-host] =>
    changed: false
    invocation:
        module_args:
            bool: true
            dict:
                key1: value 1
                key2: 2
            dict_options:
                bool: false
                int: 1
            float: 1.234
            int: 2
            json: '{"key1":"value 1","key2":2}'
            list:
            - value 1
            - value 2
            list_elements:
            - 1
            - 2
            list_of_dicts:
            -   bool: false
                int: 1
            -   bool: true
                int: 2
            path: C:\WINDOWS\System32
            raw: '1'
            sid: S-1-5-18
            str: '1'
```

### 6. Creating our own module
Now we have a better understanding of the module input and output we can start to create our module to manage a resource.
For this example we will have a basic module that managed repositories for the new `PSResourceGet` module.
We can start with creating a copy of [6_module.ps1](./collections/ansible_collections/pwsh/conf/plugins/modules/6_module.ps1) as a new file called `psrepository.ps1` in the same directory.

The first iteration should be able to handle creating and removing a repository which means we need an option to.

+ The name of the repository
+ Control the state of the repository
+ The URL of the repository when the state is to create it

```powershell
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
```

We can see that the auto validation comes into play automatically when no `name` is specified or the `url` isn't set when `state=present`

```bash
ansible windows --playbook-dir . -m pwsh.conf.psrepository

win-host | FAILED! =>
    changed: false
    msg: 'missing required arguments: name'

ansible windows --playbook-dir . -m pwsh.conf.psrepository -a 'name=foo state=present'

win-host | FAILED! =>
    changed: false
    msg: 'state is present but all of the following are missing: url'
```

Now we have the argument spec the next step is to implement the logic for either state options.
There are three typical states we need to take into account for this type of operation:

+ `state=absent` and the repository exists
+ `state=present` and the repository does not exist
+ `state=present` and one of the desired options is not set

To do this we typically shape the module into four parts:

1. Get the current state
2. Code to handle `state=absent` and the repo exists
3. Code to handle `state=present` and the repo does not exist
4. code to handle `state=present` and the repo exists but needs to be checked

We can compare out work with [6_psrepository_stage1.ps1](./collections/ansible_collections/pwsh/conf/plugins/modules/6_psrepository_stage1.ps1) to see a reference implementation.

Once we are happy with our work we can test it out to see if it works or not.

```bash
ansible windows --playbook-dir . -m pwsh.conf.psrepository -a 'name=PSConfEU url=http://foo.com'
ansible windows -m ansible.windows.win_powershell -a 'script="Get-PSResourceRepository -Name PSConfEU"'

ansible windows --playbook-dir . -m pwsh.conf.psrepository -a 'name=PSConfEU url=http://bar.com'
ansible windows -m ansible.windows.win_powershell -a 'script="Get-PSResourceRepository -Name PSConfEU"'

ansible windows --playbook-dir . -m pwsh.conf.psrepository -a 'name=PSConfEU state=absent'
ansible windows -m ansible.windows.win_powershell -a 'script="Get-PSResourceRepository -Name PSConfEU -ErrorAction SilentlyContinue"'
```

Repeating each command will also result in no change being detected demonstrating the idempotency of the module.

### 7. Debugging on Windows
Writing modules and debugging problems isn't the best experience when being done only through Ansible.
At these times it is far easier to debug the scripts directly on the Windows host.
While there is some documentation at https://docs.ansible.com/ansible/latest/dev_guide/developing_modules_general_windows.html#windows-debugging it is in some need of some improvement.

In this example we have a copy of our `psrepository` module with a bug that may be hard to figure out by looking at it.
When running the command below we would expect the first to report a change and the second no change

```bash
ansible windows --playbook-dir . -m pwsh.conf.7_psrepository_debug -a 'name=PSConfEU url=http://foo.com'

win-host | CHANGED =>
    changed: true

ansible windows --playbook-dir . -m pwsh.conf.7_psrepository_debug -a 'name=PSConfEU url=http://foo.com'

win-host | CHANGED =>
    changed: true
```

We could edit the file locally and add some return results to get a better understanding of what's going on but this may not be easy for more complex examples.
Instead lets setup an environment on Windows that can debug this module interactively.
On the Windows host, open up PowerShell, change to a directory where you want to create the `PSConfEU` folder with the module launcher code.
Once in that directory run the following code to setup the VSCode tasks and module launcher script.

```powershell
$devPath = Join-Path $pwd.Path 'PSConfEU'
if (-not (Test-Path -LiteralPath $devPath)) {
    New-Item -Path $devPath -ItemType Directory -Force
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

code $devPath
```

Copy across [7_psrepository_debug.ps1](collections/ansible_collections/pwsh/conf/plugins/modules/7_psrepository_debug.ps1) and place it in `$devPath\psrepository.ps1` directory created from the script above.
Also create a JSON file called `psrepository.json` with the following content in the same folder:

```json
{
    "name": "PSConfEU",
    "url": "http://foo.com"
}
```

Open up the `psrepository.ps1` script, place a breakpoint after the module is created on line 17 and press F5 to start debugging.
As we step through the code as it runs we can see that the input options are coming through as expected there is a typo when checking the existing `Uri` value to our `url` option so it things the `url` is different.
Fixing our typo of `$repository.Url` to `$repository.Uri` on line 31 and rerunning the code we can see the expected return result will now not report a change.

```json
{"changed":false,"invocation":{"module_args":{"url":"http://foo.com","state":"present","name":"PSConfEU"}}}
```

Now we have fixed our module we can make the changes locally and run it again to verify it worked.
Before moving onto the next stage we should clear out out test repo with

```bash
ansible windows --playbook-dir . -m pwsh.conf.psrepository -a 'name=PSConfEU state=absent'
```

Debugging modules interactively is in invaluable tool when it comes to making your own modules.
It gets more important as the code becomes more complex and the code branches are not as apparent.

### 8. Check Mode and Diff Output Support
Now we have a basic module in place we should look into add support for check mode and diff output.
Check mode is like the `-WhatIf` parameter in PowerShell where Ansible will check to see if a change should be made but not actually make the change.
Modules by default do not support check mode which we can see if we try and run our module in check mode with the `--check` argument:

```bash
ansible windows --playbook-dir . -m pwsh.conf.psrepository -a 'name=PSConfEU url=http://foo.com' --check

win-host | SKIPPED
```

To add support for check mode to a module we need to add `supports_check_mode = $true` to the argument spec:

```powershell
$spec = @{
    options = @{...}
    supports_check_mode = $true
}
```

We also need to actually implement the logic to not make the change when running in check mode.
In our example we can take advantage of `-WhatIf` on the builtin cmdlets, in other cases we might just need a simple if statement around the code that makes the changes.
The `$module` object contains a property `$module.CheckMode` which is set to `$true` when running in check mode.

```powershell
# Taking advantage of -WhatIf
Register-PSResourceRepository ... -WhatIf:$module.CheckMode

# If the cmdlet doesn't offer -WhatIf we need an if statement
if (-not $module.CheckMode) {
    Register-PSResourceRepository ...
}
```

After making the changes to your copy of `psrepository.ps1` to support check mode we can now try out our changes to see if it worked or not.

```bash
ansible windows --playbook-dir . -m pwsh.conf.psrepository -a 'name=PSConfEU url=http://foo.com' --check
win-host | CHANGED =>
    changed: true

ansible windows -m ansible.windows.win_powershell -a 'script="Get-PSResourceRepository -Name PSConfEU -ErrorAction SilentlyContinue"'

# Output should be empty
win-host | CHANGED =>
    changed: true
    debug: []
    error: []
    host_err: ''
    host_out: ''
    information: []
    output: []
    result: {}
    verbose: []
    warning: []

# Actually create it for our absent check mode test
ansible windows --playbook-dir . -m pwsh.conf.psrepository -a 'name=PSConfEU url=http://foo.com'

ansible windows --playbook-dir . -m pwsh.conf.psrepository -a 'name=PSConfEU state=absent' --check

# Should still be registered
ansible windows -m ansible.windows.win_powershell -a 'script="Get-PSResourceRepository -Name PSConfEU"'

# Cleanup now we are happy
ansible windows --playbook-dir . -m pwsh.conf.psrepository -a 'name=PSConfEU state=absent'
```

Diff mode is Ansible is enabled through the `--diff` argument, it is a nice way to display the changes that were actually made on the remote host.
Implementing support is done through the `$module.Diff` property, specifically the `before` and `after` keys in that property.
The `before` value should be set to the state of the resource before the change happened and `after` for the end state.
Use `$null` to represent the resource not existing and a hashtable of the options that represent the state.
The keys in this state should reflect the module options so that end users can understand how they map together.

The first step would be to define the default state for the `before` and `after` as `$null`, typically this is placed near the beginning near the option handling:

```powershell
$module.Diff.before = $null
$module.Diff.after = $null
```

After we retrieve the initial repository information we can fill out the `before` key with the repo details as they match up to our module options.

```powershell
$repository = Get-PSResourceRepository ...

if ($repository) {
    $module.Diff.before = @{
        name = $repository.Name
        url = $repository.Uri
    }
}
```

The next step is to fill in the `after` state, for `state=absent` nothing needs to be done as we already defined `after` as `$null`.
For `state=present` we need to handle the case where we are editing an existing repository or creating a new one.

For editing we can create a copy of the `before` state and just edit the keys when a change was detected:

```powershell
$module.Diff.after = $module.Diff.before.Clone()

if ($repository.Uri -ne $url) {
    $changeParams.Uri = $url
    $module.Diff.after = $url
}
```

For creating we just build the hashtable manually like we did for `before`

```powershell
$module.Diff.after = @{
    name = $name
    url = $url
}
```

Running with these changes we can see the new output with the `--diff` details

```bash
ansible windows --playbook-dir . -m pwsh.conf.psrepository -a 'name=PSConfEU url=http://foo.com' --diff

diff
--- before
+++ after
@@ -0,0 +1,3 @@
+    name: PSConfEU
+    url: http://foo.com
+

win-host | CHANGED =>
    changed: true


ansible windows --playbook-dir . -m pwsh.conf.psrepository -a 'name=PSConfEU url=http://foo.com' --diff

--- before
+++ after
@@ -1,3 +1,3 @@
     name: PSConfEU
-    url: http://foo.com/
+    url: http://bar.com


win-host | CHANGED =>
    changed: true


ansible windows --playbook-dir . -m pwsh.conf.psrepository -a 'name=PSConfEU state=absent' --diff
--- before
+++ after
@@ -1,3 +0,0 @@
-    name: PSConfEU
-    url: http://bar.com/
-

win-host | CHANGED =>
    changed: true
```

If your terminal supports colours then the output is a lot easier to see.
In the examples above we can see what happens when a repo was created, edited, and removed.

When attempting to interactively debug check and diff mode in VSCode we need to add the following to the json args:

```json
{
    "_ansible_check_mode": true,
    "_ansible_diff": true
}
```

All modules should strive to support at least check mode, offering diff output is nice but sometimes might be too much of a burden to implement.

### 9. Adding documentation
We have a working module, the next important step is to document the module to make it simpler for others to understand and use our module.
If we try to view the docs for our module using `ansible-doc --playbook-dir . pwsh.conf.psrepository` it will error out.

In the past module documentation was done by embedding YAML strings in an adjoining `$module.py` file next to our `$module.ps1` file but since Ansible 2.15 we can use the side-car feature to define it directly as a `YAML` file.

To start with, let's create a copy of the template module documentation file [9_module.yml](./collections/ansible_collections/pwsh/conf/plugins/modules/9_module.yml) in the same directory under the file `psrepository.yml` to match our module.
The documentation has 3 sections:

+ `DOCUMENTATION` - Module information and option details
+ `EXAMPLES` - Tasks to show how it can be used as an Ansible task
+ `RETURN` - Define return values

Filling in the examples we should now see that `ansible-doc pwsh.conf.psrepository` is able to display our docs.
See [9_psrepository.yml](./collections/ansible_collections/pwsh/conf/plugins/modules/9_psrepository.yml) for what the documentation file should look like.

### 10. Testing
Writing tests is extremely important in ensuring that the code we've written acts the way it should and also helps to avoid regressions being added in the future.
So far we've just been manually testing our changes, we should take the next step to properly test our module.
For collections we use the `ansible-test` command to do both sanity and integration tests.
This command must be run in the collection root directory, so all subsequence commands in this section will be run in [collections/ansible_collections/pwsh/conf](./collections/ansible_collections/pwsh/conf).

The first set of tests we should run is some sanity tests to validate our module matches pre-defined rules for our code and things like the documentation align with our module arg spec.
The following command can do some very basic sanity tests, please note this will require internet access to download the required libraries needed for the tests.
You can add `--docker default` to the end to run the tests in a pre-built container with all the deps, but keep in mind this is a large container so can take some time to download.

```bash
# This must be run in collections/ansible_collections/pwsh/conf
ansible-test sanity --test pslint --test validate-modules --test ansible-doc
```

Here is a brief breakdown on each test

+ `pslint` - Runs `PSScriptAnalyzer` with some pre-set rules
+ `validate-modules` - Verifies the module arg spec matches the documentation provided
+ `ansible-doc` - Basic documentation checks to ensure it is valid (like we did above)

The next important step is to create some integration tests to test out our module.
These tests are written as Ansible tasks that call the module with pre-configured options.
The tests are located in the `tests/integration/targets/$moduleName/tasks/main.yml` relative to the collection root.
For our `psrepository` module we have some existing tests already written at [collections/ansible_collections/pwsh/conf/tests/integration/targets/psrepository](./collections/ansible_collections/pwsh/conf/tests/integration/targets/psrepository).
The only extra file is the [collections/ansible_collections/pwsh/conf/tests/integration/targets/psrepository/aliases](./collections/ansible_collections/pwsh/conf/tests/integration/targets/psrepository/aliases) which identifies the target as a Windows test.

Typically tests follow the pattern:

+ Run in check mode
  + Make a change
  + Get result
  + Assert result
+ Run in normal mode
  + Make a change
  + Get result
  + Assert result
+ Run again for idempotency
  + Repeat task from previous step
  + Assert no change occurred

There is no hard rule to follow the above, it is just a common pattern that has worked well when developing modules.

Before running the tests we will need to copy our inventory file to [collections/ansible_collections/pwsh/conf/tests/integration](./collections/ansible_collections/pwsh/conf/tests/integration) under the filename `inventory.winrm`.

```bash
cp inventory collections/ansible_collections/tests/integration/inventory.winrm
```

This file is used by `ansible-test` as the test inventory and will run the test target under the hosts of the `windows` group.
To run the tests we run the following command:

```bash
# This must be run in the collection root
ansible-test windows-integration psrepository
```

The last argument is the test target to run, you can specify multiple args if you wish to run multiple targets.
The command also accepts the `-v*` and `--diff` argument like the normal `ansible` commands.

### 11. Action Plugins
Action plugins can be used to extend the functionality of a module.
As they are run on the Ansible host it can perform actions local to the Ansible host.
It even has access to the host variables of the target host allowing it to perform templating operations.
An action plugin can run specific commands on the target host, copy/fetch files to/from the target host and run any number of modules when it runs.
For example the `win_copy` module is implemented as an action plugin that invokes `win_stat` to get the remote file statistics, copies a file through the connection plugin, then invokes the `win_copy` module to copy that file into place.

An example action plugin is the [smb_copy.py](./collections/ansible_collections/ansible/windows/plugins/action/smb_copy.py) which is similar to `win_copy` but will transfer the file using the SMB protocol which is faster than WinRM.