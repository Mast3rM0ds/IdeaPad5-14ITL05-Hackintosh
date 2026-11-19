// Backlight device for internal display brightness (Coffee Lake+ / Xe: _UID 0x13).
DefinitionBlock ("", "SSDT", 2, "VOID", "PNLF", 0x00001000)
{
    Scope (\_SB)
    {
        Device (PNLF)
        {
            Name (_HID, EisaId ("APP0002"))
            Name (_CID, "backlight")
            Name (_UID, 0x13)
            Method (_STA, 0, NotSerialized)
            {
                If (_OSI ("Darwin")) { Return (0x0B) }
                Return (Zero)
            }
        }
    }
}
