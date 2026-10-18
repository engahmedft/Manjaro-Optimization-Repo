Things the Script Cannot Do Automatically (Manual Checklist)
The following items involve UEFI hardware firmware or in-app sandboxed settings and cannot be handled safely from a root bash script:
Battery Longevity Threshold (Dell BIOS):
Why: Your battery is at 43% health. Capping the charge level protects it when plugged in.
How: Reboot, tap F2 to enter Dell UEFI setup 
→
→
 Navigate to Power / Battery 
→
→
 Change Charge Configuration from Standard to Primarily AC Use (or Custom: 50% start, 80% stop).
Reduce POST Time (Dell BIOS):
Why: Your motherboard spends 9.1 seconds testing memory and buses before loading Manjaro.
How: In BIOS (F2) 
→
→
 Navigate to POST Behavior 
→
→
 Set Fastboot to Minimal.
Chrome Wayland & Video Hardware Acceleration:
Why: Chrome handles its own internal configuration independently of system packages.
How:
Open Google Chrome.
In the URL bar, go to chrome://flags.
Set Preferred Ozone platform to Wayland.
Set Hardware-accelerated video decode to Enabled.
Relaunch Chrome.
Add Antigravity CLI to your Shell Path (If using Zsh):
Why: The installer places the agy binary in ~/.local/bin.
How: Run this once in your terminal so you can use the agy command from anywhere:
code
Bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
