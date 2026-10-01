/// Single source of truth for visible country names (Spanish).
///
/// Codes stay internal (ISO 3166-1 alpha-2, plus the UK football nations as
/// ISO 3166-2 subdivisions). Users only ever see [countryDisplayName]; an
/// unknown code yields null so callers never fall back to showing a raw code.
library;

const Map<String, String> _countryNames = {
  'AD': 'Andorra',
  'AE': 'Emiratos Árabes Unidos',
  'AF': 'Afganistán',
  'AG': 'Antigua y Barbuda',
  'AI': 'Anguila',
  'AL': 'Albania',
  'AM': 'Armenia',
  'AO': 'Angola',
  'AQ': 'Antártida',
  'AR': 'Argentina',
  'AS': 'Samoa Americana',
  'AT': 'Austria',
  'AU': 'Australia',
  'AW': 'Aruba',
  'AX': 'Islas Aland',
  'AZ': 'Azerbaiyán',
  'BA': 'Bosnia y Herzegovina',
  'BB': 'Barbados',
  'BD': 'Bangladés',
  'BE': 'Bélgica',
  'BF': 'Burkina Faso',
  'BG': 'Bulgaria',
  'BH': 'Baréin',
  'BI': 'Burundi',
  'BJ': 'Benín',
  'BL': 'San Bartolomé',
  'BM': 'Bermudas',
  'BN': 'Brunéi',
  'BO': 'Bolivia',
  'BQ': 'Caribe Neerlandés',
  'BR': 'Brasil',
  'BS': 'Bahamas',
  'BT': 'Bután',
  'BV': 'Isla Bouvet',
  'BW': 'Botsuana',
  'BY': 'Bielorrusia',
  'BZ': 'Belice',
  'CA': 'Canadá',
  'CC': 'Islas Cocos',
  'CD': 'República Democrática del Congo',
  'CF': 'República Centroafricana',
  'CG': 'Congo',
  'CH': 'Suiza',
  'CI': 'Costa de Marfil',
  'CK': 'Islas Cook',
  'CL': 'Chile',
  'CM': 'Camerún',
  'CN': 'China',
  'CO': 'Colombia',
  'CR': 'Costa Rica',
  'CU': 'Cuba',
  'CV': 'Cabo Verde',
  'CW': 'Curazao',
  'CX': 'Isla de Navidad',
  'CY': 'Chipre',
  'CZ': 'Chequia',
  'DE': 'Alemania',
  'DJ': 'Yibuti',
  'DK': 'Dinamarca',
  'DM': 'Dominica',
  'DO': 'República Dominicana',
  'DZ': 'Argelia',
  'EC': 'Ecuador',
  'EE': 'Estonia',
  'EG': 'Egipto',
  'EH': 'Sáhara Occidental',
  'ER': 'Eritrea',
  'ES': 'España',
  'ET': 'Etiopía',
  'FI': 'Finlandia',
  'FJ': 'Fiyi',
  'FK': 'Islas Malvinas',
  'FM': 'Micronesia',
  'FO': 'Islas Feroe',
  'FR': 'Francia',
  'GA': 'Gabón',
  'GB': 'Reino Unido',
  'GD': 'Granada',
  'GE': 'Georgia',
  'GF': 'Guayana Francesa',
  'GG': 'Guernsey',
  'GH': 'Ghana',
  'GI': 'Gibraltar',
  'GL': 'Groenlandia',
  'GM': 'Gambia',
  'GN': 'Guinea',
  'GP': 'Guadalupe',
  'GQ': 'Guinea Ecuatorial',
  'GR': 'Grecia',
  'GS': 'Islas Georgias del Sur y Sandwich del Sur',
  'GT': 'Guatemala',
  'GU': 'Guam',
  'GW': 'Guinea-Bisáu',
  'GY': 'Guyana',
  'HK': 'Hong Kong',
  'HM': 'Islas Heard y McDonald',
  'HN': 'Honduras',
  'HR': 'Croacia',
  'HT': 'Haití',
  'HU': 'Hungría',
  'ID': 'Indonesia',
  'IE': 'Irlanda',
  'IL': 'Israel',
  'IM': 'Isla de Man',
  'IN': 'India',
  'IO': 'Territorio Británico del Océano Índico',
  'IQ': 'Irak',
  'IR': 'Irán',
  'IS': 'Islandia',
  'IT': 'Italia',
  'JE': 'Jersey',
  'JM': 'Jamaica',
  'JO': 'Jordania',
  'JP': 'Japón',
  'KE': 'Kenia',
  'KG': 'Kirguistán',
  'KH': 'Camboya',
  'KI': 'Kiribati',
  'KM': 'Comoras',
  'KN': 'San Cristóbal y Nieves',
  'KP': 'Corea del Norte',
  'KR': 'Corea del Sur',
  'KW': 'Kuwait',
  'KY': 'Islas Caimán',
  'KZ': 'Kazajistán',
  'LA': 'Laos',
  'LB': 'Líbano',
  'LC': 'Santa Lucía',
  'LI': 'Liechtenstein',
  'LK': 'Sri Lanka',
  'LR': 'Liberia',
  'LS': 'Lesoto',
  'LT': 'Lituania',
  'LU': 'Luxemburgo',
  'LV': 'Letonia',
  'LY': 'Libia',
  'MA': 'Marruecos',
  'MC': 'Mónaco',
  'MD': 'Moldavia',
  'ME': 'Montenegro',
  'MF': 'San Martín',
  'MG': 'Madagascar',
  'MH': 'Islas Marshall',
  'MK': 'Macedonia del Norte',
  'ML': 'Malí',
  'MM': 'Myanmar',
  'MN': 'Mongolia',
  'MO': 'Macao',
  'MP': 'Islas Marianas del Norte',
  'MQ': 'Martinica',
  'MR': 'Mauritania',
  'MS': 'Montserrat',
  'MT': 'Malta',
  'MU': 'Mauricio',
  'MV': 'Maldivas',
  'MW': 'Malaui',
  'MX': 'México',
  'MY': 'Malasia',
  'MZ': 'Mozambique',
  'NA': 'Namibia',
  'NC': 'Nueva Caledonia',
  'NE': 'Níger',
  'NF': 'Isla Norfolk',
  'NG': 'Nigeria',
  'NI': 'Nicaragua',
  'NL': 'Países Bajos',
  'NO': 'Noruega',
  'NP': 'Nepal',
  'NR': 'Nauru',
  'NU': 'Niue',
  'NZ': 'Nueva Zelanda',
  'OM': 'Omán',
  'PA': 'Panamá',
  'PE': 'Perú',
  'PF': 'Polinesia Francesa',
  'PG': 'Papúa Nueva Guinea',
  'PH': 'Filipinas',
  'PK': 'Pakistán',
  'PL': 'Polonia',
  'PM': 'San Pedro y Miquelón',
  'PN': 'Islas Pitcairn',
  'PR': 'Puerto Rico',
  'PS': 'Palestina',
  'PT': 'Portugal',
  'PW': 'Palaos',
  'PY': 'Paraguay',
  'QA': 'Catar',
  'RE': 'Reunión',
  'RO': 'Rumania',
  'RS': 'Serbia',
  'RU': 'Rusia',
  'RW': 'Ruanda',
  'SA': 'Arabia Saudita',
  'SB': 'Islas Salomón',
  'SC': 'Seychelles',
  'SD': 'Sudán',
  'SE': 'Suecia',
  'SG': 'Singapur',
  'SH': 'Santa Elena',
  'SI': 'Eslovenia',
  'SJ': 'Svalbard y Jan Mayen',
  'SK': 'Eslovaquia',
  'SL': 'Sierra Leona',
  'SM': 'San Marino',
  'SN': 'Senegal',
  'SO': 'Somalia',
  'SR': 'Surinam',
  'SS': 'Sudán del Sur',
  'ST': 'Santo Tomé y Príncipe',
  'SV': 'El Salvador',
  'SX': 'Sint Maarten',
  'SY': 'Siria',
  'SZ': 'Esuatini',
  'TC': 'Islas Turcas y Caicos',
  'TD': 'Chad',
  'TF': 'Territorios Australes Franceses',
  'TG': 'Togo',
  'TH': 'Tailandia',
  'TJ': 'Tayikistán',
  'TK': 'Tokelau',
  'TL': 'Timor Oriental',
  'TM': 'Turkmenistán',
  'TN': 'Túnez',
  'TO': 'Tonga',
  'TR': 'Turquía',
  'TT': 'Trinidad y Tobago',
  'TV': 'Tuvalu',
  'TW': 'Taiwán',
  'TZ': 'Tanzania',
  'UA': 'Ucrania',
  'UG': 'Uganda',
  'UM': 'Islas Ultramarinas de Estados Unidos',
  'US': 'Estados Unidos',
  'UY': 'Uruguay',
  'UZ': 'Uzbekistán',
  'VA': 'Ciudad del Vaticano',
  'VC': 'San Vicente y las Granadinas',
  'VE': 'Venezuela',
  'VG': 'Islas Vírgenes Británicas',
  'VI': 'Islas Vírgenes de los Estados Unidos',
  'VN': 'Vietnam',
  'VU': 'Vanuatu',
  'WF': 'Wallis y Futuna',
  'WS': 'Samoa',
  'XK': 'Kosovo',
  'YE': 'Yemen',
  'YT': 'Mayotte',
  'ZA': 'Sudáfrica',
  'ZM': 'Zambia',
  'ZW': 'Zimbabue',
  // Football nations inside the United Kingdom.
  'GB-ENG': 'Inglaterra',
  'GB-SCT': 'Escocia',
  'GB-WLS': 'Gales',
  'GB-NIR': 'Irlanda del Norte',
};

/// Supranational buckets of the competition catalog (`country_catalog` rows
/// flagged `is_supranational`). Display-only: never a selectable country.
const Map<String, String> _regionNames = {
  'EUROPE': 'Europa',
  'SAMERICA': 'Sudamérica',
  'NAMERICA': 'Norteamérica',
  'CAMERICA': 'Centroamérica',
  'ASIA': 'Asia',
  'AFRICA': 'África',
  'OCEANIA': 'Oceanía',
  'WORLD': 'Internacional',
};

/// Provider region tokens that reach raw `country` fields (lowercase), mapped
/// to the catalog's region codes. Mirrors the server catalog aliases plus the
/// provider buckets it leaves unresolved (`intl`, `Worldcup`).
const Map<String, String> _providerRegionCodes = {
  'europe': 'EUROPE',
  'eurocups': 'EUROPE',
  'uefa': 'EUROPE',
  'south america': 'SAMERICA',
  'conmebol': 'SAMERICA',
  'north america': 'NAMERICA',
  'central america': 'CAMERICA',
  'concacaf': 'CAMERICA',
  'asia': 'ASIA',
  'afc': 'ASIA',
  'africa': 'AFRICA',
  'caf': 'AFRICA',
  'oceania': 'OCEANIA',
  'ofc': 'OCEANIA',
  'world': 'WORLD',
  'worldcup': 'WORLD',
  'international': 'WORLD',
  'intl': 'WORLD',
};

String? _canonical(String? code) {
  final value = code?.trim().toUpperCase();
  return value == null || value.isEmpty ? null : value;
}

/// Visible, localized name for a country code, or null when unknown.
String? countryDisplayName(String? code) => _countryNames[_canonical(code)];

/// Visible label for an entity's country or region (Spanish).
///
/// The canonical [countryCode] wins (ISO country, UK football nation or a
/// catalog region). Otherwise the provider's [rawCountry] is used when it is a
/// known region token or reads as a human name. Codes and unknown tokens
/// (`intl`, `XYZ`, `world_cup`) yield null: callers hide the label instead of
/// ever showing a raw code.
String? countryLabel(String? countryCode, [String? rawCountry]) {
  final code = _canonical(countryCode);
  final known = _countryNames[code] ?? _regionNames[code];
  if (known != null) return known;
  final raw = rawCountry?.trim() ?? '';
  if (raw.isEmpty) return null;
  final region = _regionNames[_providerRegionCodes[raw.toLowerCase()]];
  if (region != null) return region;
  final asCode = _countryNames[_canonical(raw)];
  if (asCode != null) return asCode;
  // A display name starts with a capital, has a lowercase letter and only
  // letters, spaces and name punctuation. Codes and tokens never do.
  final looksLikeName =
      RegExp(r"^[A-ZÀ-Ý][\p{L} .'’()-]*$", unicode: true).hasMatch(raw) &&
      RegExp(r'\p{Ll}', unicode: true).hasMatch(raw);
  return looksLikeName ? raw : null;
}

/// Every selectable preference country (ISO 3166-1 alpha-2 only; the UK
/// football nations are display-only).
Iterable<String> get selectableCountryCodes =>
    _countryNames.keys.where((code) => code.length == 2);

/// Flag emoji for an ISO 3166-1 alpha-2 code; null for anything else.
String? countryFlag(String? code) {
  final value = _canonical(code);
  if (value == null || !RegExp(r'^[A-Z]{2}$').hasMatch(value)) return null;
  return String.fromCharCodes(value.codeUnits.map((c) => 0x1F1E6 + c - 0x41));
}

/// Case- and accent-insensitive match of a country's visible name.
bool countryMatches(String code, String query) {
  final name = countryDisplayName(code);
  if (name == null) return false;
  String fold(String value) => value
      .toLowerCase()
      .replaceAll(RegExp('[áàä]'), 'a')
      .replaceAll(RegExp('[éèë]'), 'e')
      .replaceAll(RegExp('[íìï]'), 'i')
      .replaceAll(RegExp('[óòö]'), 'o')
      .replaceAll(RegExp('[úùü]'), 'u')
      .replaceAll('ñ', 'n');
  return fold(name).contains(fold(query.trim()));
}
