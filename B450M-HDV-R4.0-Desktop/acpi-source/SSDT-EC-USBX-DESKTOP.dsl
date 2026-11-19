// Fake EC (AppleBusPowerController needs a device named EC) + USB power properties.
// AMD 400-series boards call the LPC bridge SBRG; LPC0/LPCB are covered too.
DefinitionBlock ("", "SSDT", 2, "VOID", "ECUSBX", 0x00001000)
{
    External (_SB_.PCI0.SBRG, DeviceObj)
    External (_SB_.PCI0.LPC0, DeviceObj)
    External (_SB_.PCI0.LPCB, DeviceObj)

    If (CondRefOf (\_SB.PCI0.SBRG))
    {
        Scope (\_SB.PCI0.SBRG)
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
    ElseIf (CondRefOf (\_SB.PCI0.LPC0))
    {
        Scope (\_SB.PCI0.LPC0)
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
                    "kUSBSleepPortCurrentLimit", 0x0BB8,
                    "kUSBWakePortCurrentLimit", 0x0BB8
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
