// Tiger Lake ships the AWAC clock instead of legacy RTC; macOS needs RTC.
// Setting STAS=1 makes the firmware expose RTC and hide AWAC under Darwin.
DefinitionBlock ("", "SSDT", 2, "VOID", "AWAC", 0x00001000)
{
    External (STAS, IntObj)

    Scope (\)
    {
        Method (_INI, 0, NotSerialized)
        {
            If (_OSI ("Darwin"))
            {
                If (CondRefOf (\STAS)) { \STAS = One }
            }
        }
    }
}
