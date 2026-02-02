Thanks for creating this, AntiGravity with Gemini 3

Setup
-----

- Modify the scripts to your liking. You'll probably want to change the default OpenVPN profile to connect to by changing the value of the $OpenVPNProfile variable in AutoVPN.ps1
- Copy both AutoVPN.ps1 and Setup.ps1 to a folder of your choice. For example C:\Users\<username>\AppData\Local\AutoVPN
- Start a Windows PowerShell and make sure you run it as an administrator
- Create the required event source by running the following command. This is only required once:
    powershell -ExecutionPolicy Bypass -File .\Setup.ps1 -CreateEventSource
- Register the tasks that will run the script at logon and when events are triggered by running the following command:
    powershell -ExecutionPolicy Bypass -File .\Setup.ps1 -TargetUser <username>
- You can optionally remove the files after the tasks are registered. If you do, you can re-register them by running the setup script again.

That's it. Happy VPN'ing!


Issues or suggestions? 
----------------------

- Please open an issue on GitHub.
