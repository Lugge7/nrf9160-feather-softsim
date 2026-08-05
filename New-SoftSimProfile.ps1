<#
Encode a SoftSIM profile string from raw SIM credentials.

Produces the TLV hex string consumed by nrf_softsim_provision() -- either as
CONFIG_SOFTSIM_STATIC_PROFILE (compiled in) or typed over serial in the
sample's external-profile mode.

    .\New-SoftSimProfile.ps1 -Imsi 295052203117000 -Iccid 8999925220311700001 `
                             -Ki 0123...  -Opc 89AB...

    .\New-SoftSimProfile.ps1 -SelfTest      # verify the encoders against the upstream example

Tag map from modules\onomondo-softsim\lib\onomondo-uicc\include\onomondo\utils\ss_profile.h:25-37
    01 IMSI (18 hex chars)   02 ICCID (20)   03 OPc (32)
    04 Ki   (32)             05 KIC   (32)   06 KID  (32)

KIC and KID are OTA SIM-management keys. Network attach never uses them, but
nrf_softsim_provision() rejects a profile where either is all-zero
(lib\nrf_softsim.c:144-152), so a non-zero placeholder is supplied by default.
#>
[CmdletBinding(DefaultParameterSetName = 'Encode')]
param(
    [Parameter(ParameterSetName = 'Encode', Mandatory)][string]$Imsi,
    [Parameter(ParameterSetName = 'Encode', Mandatory)][string]$Iccid,
    [Parameter(ParameterSetName = 'Encode', Mandatory)][string]$Ki,
    [Parameter(ParameterSetName = 'Encode', Mandatory)][string]$Opc,
    [Parameter(ParameterSetName = 'Encode')][string]$Kic = '000102030405060708090A0B0C0D0E0F',
    [Parameter(ParameterSetName = 'Encode')][string]$Kid = '000102030405060708090A0B0C0D0E0F',
    [Parameter(ParameterSetName = 'SelfTest', Mandatory)][switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

# EF.IMSI (TS 31.102): length byte, then a nibble holding the parity flag beside
# the first digit, then the remaining digits as swapped-nibble BCD.
function ConvertTo-EfImsi([string]$imsi) {
    if ($imsi -notmatch '^\d{6,15}$') { throw "IMSI must be 6-15 digits. Got '$imsi'." }
    $d = $imsi.ToCharArray()
    # Low nibble carries the parity flag (9 = odd digit count, 1 = even),
    # high nibble carries the first IMSI digit. So "09" is digit 0, odd length.
    $parity = '1'; if ($d.Count % 2 -eq 1) { $parity = '9' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append([string]$d[0]).Append($parity)
    for ($i = 1; $i -lt $d.Count; $i += 2) {
        $lo = [string]$d[$i]
        $hi = 'F'; if ($i + 1 -lt $d.Count) { $hi = [string]$d[$i + 1] }
        [void]$sb.Append($hi).Append($lo)
    }
    $body = $sb.ToString()
    if ($body.Length % 2 -ne 0) { $body += 'F' }
    return ('{0:X2}' -f ($body.Length / 2)) + $body
}

# EF.ICCID: 10 bytes of swapped-nibble BCD, F-padded to 20 digits.
function ConvertTo-EfIccid([string]$iccid) {
    if ($iccid -notmatch '^\d{18,20}$') { throw "ICCID must be 18-20 digits. Got '$iccid' ($($iccid.Length))." }
    $s = $iccid
    while ($s.Length -lt 20) { $s += 'F' }
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt 20; $i += 2) { [void]$sb.Append($s[$i + 1]).Append($s[$i]) }
    return $sb.ToString()
}

function New-Tlv([int]$tag, [string]$value) {
    return ('{0:X2}{1:X2}' -f $tag, $value.Length) + $value.ToUpper()
}

function New-Profile([string]$imsi, [string]$iccid, [string]$ki, [string]$opc, [string]$kic, [string]$kid) {
    foreach ($p in @(@{n='Ki';v=$ki}, @{n='OPc';v=$opc}, @{n='KIC';v=$kic}, @{n='KID';v=$kid})) {
        if ($p.v -notmatch '^[0-9A-Fa-f]{32}$') { throw "$($p.n) must be 32 hex chars. Got '$($p.v)'." }
        # nrf_softsim.c checks is_all_zero() on the hex-ASCII field, where "000...0"
        # is 0x30 bytes rather than NULs -- so an all-zero key is accepted (the GSMA
        # TS.48 test profile ships exactly that for OPc). Warn rather than reject.
        if ($p.v -match '^0{32}$') { Write-Warning "$($p.n) is all zeros. Valid per the library, but verify it against what your operator issued." }
    }
    return (New-Tlv 0x01 (ConvertTo-EfImsi $imsi)) +
           (New-Tlv 0x02 (ConvertTo-EfIccid $iccid)) +
           (New-Tlv 0x03 $opc) +
           (New-Tlv 0x04 $ki) +
           (New-Tlv 0x05 $kic) +
           (New-Tlv 0x06 $kid)
}

if ($SelfTest) {
    # The example string carried in the upstream sample's prj.conf.
    $expected = '01120809101010325476980214980010325476981032140320' +
                '00000000000000000000000000000000' +
                '0420000102030405060708090A0B0C0D0E0F' +
                '0520000102030405060708090A0B0C0D0E0F' +
                '0620000102030405060708090A0B0C0D0E0F'

    $imsiField  = ConvertTo-EfImsi  '001010123456789'
    $iccidField = ConvertTo-EfIccid '89000123456789012341'
    $okImsi  = ($imsiField  -eq '080910101032547698')
    $okIccid = ($iccidField -eq '98001032547698103214')

    "IMSI  001010123456789      -> $imsiField   $(if($okImsi){'OK'}else{'MISMATCH (expected 080910101032547698)'})"
    "ICCID 89000123456789012341 -> $iccidField $(if($okIccid){'OK'}else{'MISMATCH (expected 98001032547698103214)'})"
    ""
    "Upstream example for reference:"
    "  $expected"
    if ($okImsi -and $okIccid) { "`nSelf-test passed." } else { throw "`nSelf-test FAILED." }
    return
}

$profile = New-Profile $Imsi $Iccid $Ki $Opc $Kic $Kid

""
"Profile ($($profile.Length) hex chars):"
"  $profile"
""
"Static build - add to apps\softsim\prj.conf:"
"  CONFIG_SOFTSIM_STATIC_PROFILE_ENABLE=y"
"  CONFIG_SOFTSIM_STATIC_PROFILE=`"$profile`""
""
"External mode - paste the line above into the serial console when prompted."
if ($Kic -eq '000102030405060708090A0B0C0D0E0F' -or $Kid -eq '000102030405060708090A0B0C0D0E0F') {
    "`nNote: KIC/KID are placeholders. Fine for network attach; OTA SIM management will not work."
}
