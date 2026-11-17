import SwiftUI

struct PhoneCountry: Identifiable, Equatable {
    let id: String
    let callingCode: String
    let nationalPrefix: String
    let mainCountry: Bool

    var name: String { Locale.current.localizedString(forRegionCode: id) ?? id }
    var title: String { "\(name) (+\(callingCode))" }

    static let all: [PhoneCountry] = countryData.split(separator: "\n").map { line in
        let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        return PhoneCountry(id: fields[0], callingCode: fields[1], nationalPrefix: fields[2], mainCountry: fields[3] == "1")
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    static var preferred: PhoneCountry {
        all.first { $0.id == Locale.current.region?.identifier }
            ?? all.first { $0.id == "US" } ?? all[0]
    }

    static func matching(_ international: String, preferredID: String) -> PhoneCountry? {
        let digits = String(international.dropFirst())
        let candidates = all.filter { digits.hasPrefix($0.callingCode) }
        let longest = candidates.map { $0.callingCode.count }.max() ?? 0
        let matches = candidates.filter { $0.callingCode.count == longest }
        return matches.first { $0.id == preferredID }
            ?? matches.first { $0.mainCountry } ?? matches.first
    }

    // Calling-code facts from Google's libphonenumber metadata, retrieved 2026-11-17.
    // https://github.com/google/libphonenumber/blob/master/resources/PhoneNumberMetadata.xml
    // National-prefix conversion is limited to simple, explicitly supported plans.
    private static let countryData = """
AC|247||0
AD|376||0
AE|971|0|0
AF|93||0
AG|1||0
AI|1||0
AL|355||0
AM|374||0
AO|244||0
AR|54||0
AS|1||0
AT|43|0|0
AU|61|0|1
AW|297||0
AX|358||0
AZ|994||0
BA|387||0
BB|1||0
BD|880|0|0
BE|32|0|0
BF|226||0
BG|359||0
BH|973||0
BI|257||0
BJ|229||0
BL|590||0
BM|1||0
BN|673||0
BO|591||0
BQ|599||0
BR|55||0
BS|1||0
BT|975||0
BW|267||0
BY|375||0
BZ|501||0
CA|1||0
CC|61||0
CD|243||0
CF|236||0
CG|242||0
CH|41|0|0
CI|225||0
CK|682||0
CL|56||0
CM|237||0
CN|86|0|0
CO|57||0
CR|506||0
CU|53||0
CV|238||0
CW|599||1
CX|61||0
CY|357||0
CZ|420||0
DE|49|0|0
DJ|253||0
DK|45||0
DM|1||0
DO|1||0
DZ|213||0
EC|593||0
EE|372||0
EG|20||0
EH|212||0
ER|291||0
ES|34||0
ET|251||0
FI|358|0|1
FJ|679||0
FK|500||0
FM|691||0
FO|298||0
FR|33|0|0
GA|241||0
GB|44|0|1
GD|1||0
GE|995||0
GF|594||0
GG|44||0
GH|233|0|0
GI|350||0
GL|299||0
GM|220||0
GN|224||0
GP|590||1
GQ|240||0
GR|30||0
GT|502||0
GU|1||0
GW|245||0
GY|592||0
HK|852||0
HN|504||0
HR|385||0
HT|509||0
HU|36||0
ID|62||0
IE|353|0|0
IL|972|0|0
IM|44||0
IN|91|0|0
IO|246||0
IQ|964||0
IR|98||0
IS|354||0
IT|39||1
JE|44||0
JM|1||0
JO|962||0
JP|81|0|0
KE|254|0|0
KG|996||0
KH|855||0
KI|686||0
KM|269||0
KN|1||0
KP|850||0
KR|82|0|0
KW|965||0
KY|1||0
KZ|7||0
LA|856||0
LB|961||0
LC|1||0
LI|423||0
LK|94||0
LR|231||0
LS|266||0
LT|370||0
LU|352||0
LV|371||0
LY|218||0
MA|212||1
MC|377||0
MD|373||0
ME|382||0
MF|590||0
MG|261||0
MH|692||0
MK|389||0
ML|223||0
MM|95||0
MN|976||0
MO|853||0
MP|1||0
MQ|596||0
MR|222||0
MS|1||0
MT|356||0
MU|230||0
MV|960||0
MW|265||0
MX|52||0
MY|60||0
MZ|258||0
NA|264||0
NC|687||0
NE|227||0
NF|672||0
NG|234|0|0
NI|505||0
NL|31|0|0
NO|47||1
NP|977||0
NR|674||0
NU|683||0
NZ|64|0|0
OM|968||0
PA|507||0
PE|51||0
PF|689||0
PG|675||0
PH|63|0|0
PK|92|0|0
PL|48||0
PM|508||0
PR|1||0
PS|970||0
PT|351||0
PW|680||0
PY|595||0
QA|974||0
RE|262||1
RO|40||0
RS|381||0
RU|7||1
RW|250||0
SA|966||0
SB|677||0
SC|248||0
SD|249||0
SE|46|0|0
SG|65||0
SH|290||1
SI|386||0
SJ|47||0
SK|421||0
SL|232||0
SM|378||0
SN|221||0
SO|252||0
SR|597||0
SS|211||0
ST|239||0
SV|503||0
SX|1||0
SY|963||0
SZ|268||0
TA|290||0
TC|1||0
TD|235||0
TG|228||0
TH|66||0
TJ|992||0
TK|690||0
TL|670||0
TM|993||0
TN|216||0
TO|676||0
TR|90||0
TT|1||0
TV|688||0
TW|886|0|0
TZ|255||0
UA|380||0
UG|256||0
US|1||1
UY|598||0
UZ|998||0
VA|39||0
VC|1||0
VE|58||0
VG|1||0
VI|1||0
VN|84||0
VU|678||0
WF|681||0
WS|685||0
XK|383||0
YE|967||0
YT|262||0
ZA|27|0|0
ZM|260||0
ZW|263||0
"""
}

/// Keeps the wire format separate from the editable text and readable display.
enum PhoneNumberText {
    static func compact(_ text: String) -> String {
        text.components(separatedBy: CharacterSet(charactersIn: "()-.\u{00a0}").union(.whitespacesAndNewlines)).joined()
    }

    static func isInternational(_ text: String) -> Bool {
        text.range(of: #"^\+[1-9][0-9]{7,14}$"#, options: .regularExpression) != nil
    }

    static func canonical(_ text: String, country: PhoneCountry?) -> String {
        var number = compact(text)
        guard !number.isEmpty else { return "" }
        if number.hasPrefix("00") { number = "+" + number.dropFirst(2) }
        if number.hasPrefix("+") { return number }
        guard let country else { return number }
        // NANP allows a leading domestic 1; preserve a normal ten-digit number.
        if country.callingCode == "1", number.count == 11, number.hasPrefix("1") {
            number.removeFirst()
        } else if !country.nationalPrefix.isEmpty, number.hasPrefix(country.nationalPrefix) {
            number = String(number.dropFirst(country.nationalPrefix.count))
        }
        return "+" + country.callingCode + number
    }

    static func isValid(_ number: String) -> Bool {
        guard isInternational(number) else { return false }
        // Catch incomplete North American numbers rather than accepting any E.164 length.
        return !number.hasPrefix("+1") || number.count == 12
    }

    static func display(_ number: String) -> String {
        let number = compact(number)
        guard isInternational(number),
              let country = PhoneCountry.matching(number, preferredID: PhoneCountry.preferred.id) else { return number }
        let local = String(number.dropFirst(country.callingCode.count + 1))
        if country.callingCode == "1", local.count == 10 {
            return "+1 (\(local.prefix(3))) \(local.dropFirst(3).prefix(3))-\(local.suffix(4))"
        }
        var groups: [String] = []
        var remaining = local[...]
        while !remaining.isEmpty {
            groups.append(String(remaining.prefix(3)))
            remaining = remaining.dropFirst(min(3, remaining.count))
        }
        return "+\(country.callingCode) " + groups.joined(separator: " ")
    }
}

struct PhoneNumberField: View {
    @Binding var phone: String
    @State private var country = PhoneCountry.preferred
    @State private var nationalNumber = ""
    @State private var internationalMode = false
    @State private var showingCountries = false
    @FocusState private var numberFocused: Bool

    private var canonical: String {
        PhoneNumberText.canonical(nationalNumber, country: internationalMode ? nil : country)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                numberFocused = false
                showingCountries = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Country / region").font(.caption).foregroundStyle(.secondary)
                        Text(internationalMode ? "International number" : country.title)
                            .font(.body.weight(.medium)).foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens a wheel to choose your country calling code.")

            TextField(internationalMode ? "International phone number" : "Phone number", text: $nationalNumber)
                .font(.title2.monospacedDigit())
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .focused($numberFocused)
                .autocorrectionDisabled()
                .onChange(of: nationalNumber) { _, value in
                    let compact = PhoneNumberText.compact(value)
                    if compact.hasPrefix("+") || compact.hasPrefix("00") {
                        let full = compact.hasPrefix("00") ? "+" + compact.dropFirst(2) : compact
                        if let detected = PhoneCountry.matching(full, preferredID: country.id) {
                            country = detected
                            internationalMode = false
                            nationalNumber = String(full.dropFirst(detected.callingCode.count + 1))
                        } else {
                            internationalMode = true
                        }
                    }
                    phone = canonical
                }

            if nationalNumber.isEmpty {
                Text(internationalMode ? "Include the country calling code when pasting a number." : "Enter your number with area code. The country code is added for you.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if PhoneNumberText.isValid(canonical) {
                Text(PhoneNumberText.display(canonical))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .accessibilityLabel("Full phone number")
                    .accessibilityValue(PhoneNumberText.display(canonical))
            } else {
                Text(country.callingCode == "1" && !internationalMode
                     ? "Enter a 10-digit number, including the area code."
                     : "Check the number. Use digits and include the area code, without an extension.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onAppear { load(phone) }
        .onChange(of: phone) { _, value in
            if value != canonical { load(value) }
        }
        .sheet(isPresented: $showingCountries) {
            PhoneCountryWheel(selection: country) { selected in
                country = selected
                internationalMode = false
                phone = canonical
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { numberFocused = false }
            }
        }
    }

    private func load(_ value: String) {
        let compact = PhoneNumberText.compact(value)
        if compact.hasPrefix("+"), let detected = PhoneCountry.matching(compact, preferredID: country.id) {
            country = detected
            internationalMode = false
            nationalNumber = String(compact.dropFirst(detected.callingCode.count + 1))
        } else {
            internationalMode = compact.hasPrefix("+")
            nationalNumber = value
        }
    }
}

private struct PhoneCountryWheel: View {
    @Environment(\.dismiss) private var dismiss
    @State var selection: PhoneCountry
    let onSelect: (PhoneCountry) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose the country for this phone number.")
                    .foregroundStyle(.secondary)
                Picker("Country / region", selection: Binding(
                    get: { selection.id },
                    set: { id in
                        if let selected = PhoneCountry.all.first(where: { $0.id == id }) { selection = selected }
                    }
                )) {
                    ForEach(PhoneCountry.all) { country in
                        Text(country.title).tag(country.id)
                    }
                }
                .pickerStyle(.wheel)
                Text(selection.title).font(.headline)
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Country code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onSelect(selection); dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
