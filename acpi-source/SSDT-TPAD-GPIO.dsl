// IdeaPad 5 14ITL05: TPAD's _CRS returns APIC IRQ 0x44, which VoodooI2C can't use.
// Under macOS return the firmware's own GpioInt (\_SB.GPI0 pin 0xC4) instead.
// Needs the ACPI patch renaming \_SB.PC00.I2C0.TPAD._CRS -> XCRS.
DefinitionBlock ("", "SSDT", 2, "VOID", "TPADGPIO", 0x00001000)
{
    External (_SB_.PC00.I2C0.TPAD, DeviceObj)
    External (_SB_.PC00.I2C0.TPAD.XCRS, MethodObj)
    External (_SB_.PC00.I2C0.TPAD.SBFB, BuffObj)
    External (_SB_.PC00.I2C0.TPAD.SBFG, BuffObj)

    Scope (\_SB.PC00.I2C0.TPAD)
    {
        Method (_CRS, 0, Serialized)
        {
            Local0 = XCRS ()   // keeps firmware side effects (I2C address, HID descriptor)
            If (_OSI ("Darwin"))
            {
                Return (ConcatenateResTemplate (SBFB, SBFG))
            }
            Return (Local0)
        }
    }
}
