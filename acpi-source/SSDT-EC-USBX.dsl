// Fake EC (for AppleBusPowerController) + USBX power properties.
// Tiger Lake firmware names the PCI root PC00; older firmware uses PCI0.
// Both paths are guarded so the table loads either way.
DefinitionBlock ("", "SSDT", 2, "VOID", "EC-USBX", 0x00001000)
{
    External (_SB_.PC00.LPCB, DeviceObj)
    External (_SB_.PCI0.LPCB, DeviceObj)

    If (CondRefOf (\_SB.PC00.LPCB))
    {
        Scope (\_SB.PC00.LPCB)
        {
            Device (EC)
            {
                Name (_HID, "ACID0001")
                Method (_STA, 0, NotSerialized)
                {
                    If (_OSI ("Darwin")) { Return (0x0F) }
                    Return (Zero)
                }
            }
        }
    }
    ElseIf (CondRefOf (\_SB.PCI0.LPCB))
    {
        Scope (\_SB.PCI0.LPCB)
        {
            Device (EC)
            {
                Name (_HID, "ACID0001")
                Method (_STA, 0, NotSerialized)
                {
                    If (_OSI ("Darwin")) { Return (0x0F) }
                    Return (Zero)
                }
            }
        }
    }

    Scope (\_SB)
    {
        Device (USBX)
        {
            Name (_ADR, Zero)
            Method (_DSM, 4, NotSerialized)
            {
                If (!Arg2) { Return (Buffer () { 0x03 }) }
                Return (Package ()
                {
                    "kUSBSleepPowerSupply", 0x13EC,
                    "kUSBSleepPortCurrentLimit", 0x0834,
                    "kUSBWakePowerSupply", 0x13EC,
                    "kUSBWakePortCurrentLimit", 0x0834
                })
            }
            Method (_STA, 0, NotSerialized)
            {
                If (_OSI ("Darwin")) { Return (0x0F) }
                Return (Zero)
            }
        }
    }
}
