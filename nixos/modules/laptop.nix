{ lib, ... }:
{
  # Keep these laptop-based cluster nodes running with their lids closed.
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
  };

  # Use the performance governor without a laptop power manager overriding it.
  powerManagement.enable = true;
  powerManagement.cpuFreqGovernor = "performance";
  services.power-profiles-daemon.enable = lib.mkForce false;
  services.tlp.enable = lib.mkForce false;
}
