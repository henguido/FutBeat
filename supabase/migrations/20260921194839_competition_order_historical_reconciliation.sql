-- Durable FutBeat-owned editorial catalog. Provider entity upserts may replace
-- their JSON wholesale without affecting this table.

create table if not exists futbeat_private.country_catalog(
  country_code text primary key,
  canonical_name text not null unique,
  aliases jsonb not null default '[]'::jsonb,
  is_supranational boolean not null default false,
  check(country_code=upper(country_code)),
  check(jsonb_typeof(aliases)='array')
);
alter table futbeat_private.country_catalog enable row level security;
revoke all on futbeat_private.country_catalog from public,anon,authenticated;

-- ISO 3166-1 alpha-2 (249 entries); localized names from Node ICU/CLDR.
-- GB remains ISO United Kingdom; football associations use GB-ENG/SCT/WLS/NIR.
insert into futbeat_private.country_catalog(country_code,canonical_name,aliases,is_supranational)
values
 ('AD','Andorra','["andorra","andorre"]',false),
 ('AE','United Arab Emirates','["united arab emirates","emiratos árabes unidos","emirados árabes unidos","émirats arabes unis"]',false),
 ('AF','Afghanistan','["afghanistan","afganistán","afeganistão"]',false),
 ('AG','Antigua & Barbuda','["antigua & barbuda","antigua y barbuda","antígua e barbuda","antigua-et-barbuda"]',false),
 ('AI','Anguilla','["anguilla","anguila"]',false),
 ('AL','Albania','["albania","albânia","albanie"]',false),
 ('AM','Armenia','["armenia","armênia","arménie"]',false),
 ('AO','Angola','["angola"]',false),
 ('AQ','Antarctica','["antarctica","antártida","antarctique"]',false),
 ('AR','Argentina','["argentina","argentine"]',false),
 ('AS','American Samoa','["american samoa","samoa americana","samoa américaines"]',false),
 ('AT','Austria','["austria","áustria","autriche"]',false),
 ('AU','Australia','["australia","austrália","australie"]',false),
 ('AW','Aruba','["aruba"]',false),
 ('AX','Åland Islands','["åland islands","islas aland","ilhas aland","îles åland"]',false),
 ('AZ','Azerbaijan','["azerbaijan","azerbaiyán","azerbaijão","azerbaïdjan"]',false),
 ('BA','Bosnia & Herzegovina','["bosnia & herzegovina","bosnia y herzegovina","bósnia e herzegovina","bosnie-herzégovine"]',false),
 ('BB','Barbados','["barbados","barbade"]',false),
 ('BD','Bangladesh','["bangladesh","bangladés"]',false),
 ('BE','Belgium','["belgium","bélgica","belgique"]',false),
 ('BF','Burkina Faso','["burkina faso","burquina faso"]',false),
 ('BG','Bulgaria','["bulgaria","bulgária","bulgarie"]',false),
 ('BH','Bahrain','["bahrain","baréin","barein","bahreïn"]',false),
 ('BI','Burundi','["burundi"]',false),
 ('BJ','Benin','["benin","benín","bénin"]',false),
 ('BL','St. Barthélemy','["st. barthélemy","san bartolomé","são bartolomeu","saint-barthélemy"]',false),
 ('BM','Bermuda','["bermuda","bermudas","bermudes"]',false),
 ('BN','Brunei','["brunei","brunéi"]',false),
 ('BO','Bolivia','["bolivia","bolívia","bolivie"]',false),
 ('BQ','Caribbean Netherlands','["caribbean netherlands","caribe neerlandés","países baixos caribenhos","pays-bas caribéens"]',false),
 ('BR','Brazil','["brazil","brasil","brésil"]',false),
 ('BS','Bahamas','["bahamas"]',false),
 ('BT','Bhutan','["bhutan","bután","butão","bhoutan"]',false),
 ('BV','Bouvet Island','["bouvet island","isla bouvet","ilha bouvet","île bouvet"]',false),
 ('BW','Botswana','["botswana","botsuana"]',false),
 ('BY','Belarus','["belarus","bielorrusia","bielorrússia","biélorussie"]',false),
 ('BZ','Belize','["belize","belice"]',false),
 ('CA','Canada','["canada","canadá"]',false),
 ('CC','Cocos (Keeling) Islands','["cocos (keeling) islands","islas cocos","ilhas cocos (keeling)","îles cocos"]',false),
 ('CD','Congo - Kinshasa','["congo - kinshasa","república democrática del congo","congo-kinshasa"]',false),
 ('CF','Central African Republic','["central african republic","república centroafricana","república centro-africana","république centrafricaine"]',false),
 ('CG','Congo - Brazzaville','["congo - brazzaville","congo","república do congo","congo-brazzaville"]',false),
 ('CH','Switzerland','["switzerland","suiza","suíça","suisse"]',false),
 ('CI','Côte d’Ivoire','["côte d’ivoire","costa do marfim","ivory coast"]',false),
 ('CK','Cook Islands','["cook islands","islas cook","ilhas cook","îles cook"]',false),
 ('CL','Chile','["chile","chili"]',false),
 ('CM','Cameroon','["cameroon","camerún","camarões","cameroun"]',false),
 ('CN','China','["china","chine"]',false),
 ('CO','Colombia','["colombia","colômbia","colombie"]',false),
 ('CR','Costa Rica','["costa rica"]',false),
 ('CU','Cuba','["cuba"]',false),
 ('CV','Cape Verde','["cape verde","cabo verde","cap-vert"]',false),
 ('CW','Curaçao','["curaçao","curazao"]',false),
 ('CX','Christmas Island','["christmas island","isla de navidad","ilha christmas","île christmas"]',false),
 ('CY','Cyprus','["cyprus","chipre","chypre"]',false),
 ('CZ','Czechia','["czechia","chequia","tchéquia","tchéquie"]',false),
 ('DE','Germany','["germany","alemania","alemanha","allemagne"]',false),
 ('DJ','Djibouti','["djibouti","yibuti","djibuti"]',false),
 ('DK','Denmark','["denmark","dinamarca","danemark"]',false),
 ('DM','Dominica','["dominica","dominique"]',false),
 ('DO','Dominican Republic','["dominican republic","república dominicana","république dominicaine"]',false),
 ('DZ','Algeria','["algeria","argelia","argélia","algérie"]',false),
 ('EC','Ecuador','["ecuador","equador","équateur"]',false),
 ('EE','Estonia','["estonia","estônia","estonie"]',false),
 ('EG','Egypt','["egypt","egipto","egito","égypte"]',false),
 ('EH','Western Sahara','["western sahara","sáhara occidental","saara ocidental","sahara occidental"]',false),
 ('ER','Eritrea','["eritrea","eritreia","érythrée"]',false),
 ('ES','Spain','["spain","españa","espana","espanha","espagne"]',false),
 ('ET','Ethiopia','["ethiopia","etiopía","etiópia","éthiopie"]',false),
 ('FI','Finland','["finland","finlandia","finlândia","finlande"]',false),
 ('FJ','Fiji','["fiji","fiyi","fidji"]',false),
 ('FK','Falkland Islands','["falkland islands","islas malvinas","ilhas malvinas","îles malouines"]',false),
 ('FM','Micronesia','["micronesia","micronésia","micronésie"]',false),
 ('FO','Faroe Islands','["faroe islands","islas feroe","ilhas faroé","îles féroé"]',false),
 ('FR','France','["france","francia","frança"]',false),
 ('GA','Gabon','["gabon","gabón","gabão"]',false),
 ('GB','United Kingdom','["united kingdom","reino unido","royaume-uni","uk","great britain"]',false),
 ('GD','Grenada','["grenada","granada","grenade"]',false),
 ('GE','Georgia','["georgia","geórgia","géorgie"]',false),
 ('GF','French Guiana','["french guiana","guayana francesa","guiana francesa","guyane française"]',false),
 ('GG','Guernsey','["guernsey","guernesey"]',false),
 ('GH','Ghana','["ghana","gana"]',false),
 ('GI','Gibraltar','["gibraltar"]',false),
 ('GL','Greenland','["greenland","groenlandia","groenlândia","groenland"]',false),
 ('GM','Gambia','["gambia","gâmbia","gambie"]',false),
 ('GN','Guinea','["guinea","guiné","guinée"]',false),
 ('GP','Guadeloupe','["guadeloupe","guadalupe"]',false),
 ('GQ','Equatorial Guinea','["equatorial guinea","guinea ecuatorial","guiné equatorial","guinée équatoriale"]',false),
 ('GR','Greece','["greece","grecia","grécia","grèce"]',false),
 ('GS','South Georgia & South Sandwich Islands','["south georgia & south sandwich islands","islas georgia del sur y sandwich del sur","ilhas geórgia do sul e sandwich do sul","géorgie du sud-et-les îles sandwich du sud"]',false),
 ('GT','Guatemala','["guatemala"]',false),
 ('GU','Guam','["guam"]',false),
 ('GW','Guinea-Bissau','["guinea-bissau","guinea-bisáu","guiné-bissau","guinée-bissau"]',false),
 ('GY','Guyana','["guyana","guiana"]',false),
 ('HK','Hong Kong SAR China','["hong kong sar china","rae de hong kong (china)","hong kong, rae da china","r.a.s. chinoise de hong kong"]',false),
 ('HM','Heard & McDonald Islands','["heard & mcdonald islands","islas heard y mcdonald","ilhas heard e mcdonald","îles heard-et-macdonald"]',false),
 ('HN','Honduras','["honduras"]',false),
 ('HR','Croatia','["croatia","croacia","croácia","croatie"]',false),
 ('HT','Haiti','["haiti","haití","haïti"]',false),
 ('HU','Hungary','["hungary","hungría","hungria","hongrie"]',false),
 ('ID','Indonesia','["indonesia","indonésia","indonésie"]',false),
 ('IE','Ireland','["ireland","irlanda","irlande"]',false),
 ('IL','Israel','["israel","israël"]',false),
 ('IM','Isle of Man','["isle of man","isla de man","ilha de man","île de man"]',false),
 ('IN','India','["india","índia","inde"]',false),
 ('IO','British Indian Ocean Territory','["british indian ocean territory","territorio británico del océano índico","território britânico do oceano índico","territoire britannique de l’océan indien"]',false),
 ('IQ','Iraq','["iraq","irak","iraque"]',false),
 ('IR','Iran','["iran","irán","irã"]',false),
 ('IS','Iceland','["iceland","islandia","islândia","islande"]',false),
 ('IT','Italy','["italy","italia","itália","italie"]',false),
 ('JE','Jersey','["jersey"]',false),
 ('JM','Jamaica','["jamaica","jamaïque"]',false),
 ('JO','Jordan','["jordan","jordania","jordânia","jordanie"]',false),
 ('JP','Japan','["japan","japón","japão","japon"]',false),
 ('KE','Kenya','["kenya","kenia","quênia"]',false),
 ('KG','Kyrgyzstan','["kyrgyzstan","kirguistán","quirguistão","kirghizstan"]',false),
 ('KH','Cambodia','["cambodia","camboya","camboja","cambodge"]',false),
 ('KI','Kiribati','["kiribati","quiribati"]',false),
 ('KM','Comoros','["comoros","comoras","comores"]',false),
 ('KN','St. Kitts & Nevis','["st. kitts & nevis","san cristóbal y nieves","são cristóvão e névis","saint-christophe-et-niévès"]',false),
 ('KP','North Korea','["north korea","corea del norte","coreia do norte","corée du nord"]',false),
 ('KR','South Korea','["south korea","corea del sur","coreia do sul","corée du sud","korea republic","republic of korea"]',false),
 ('KW','Kuwait','["kuwait","koweït"]',false),
 ('KY','Cayman Islands','["cayman islands","islas caimán","ilhas cayman","îles caïmans"]',false),
 ('KZ','Kazakhstan','["kazakhstan","kazajistán","cazaquistão"]',false),
 ('LA','Laos','["laos"]',false),
 ('LB','Lebanon','["lebanon","líbano","liban"]',false),
 ('LC','St. Lucia','["st. lucia","santa lucía","santa lúcia","sainte-lucie"]',false),
 ('LI','Liechtenstein','["liechtenstein"]',false),
 ('LK','Sri Lanka','["sri lanka"]',false),
 ('LR','Liberia','["liberia","libéria"]',false),
 ('LS','Lesotho','["lesotho","lesoto"]',false),
 ('LT','Lithuania','["lithuania","lituania","lituânia","lituanie"]',false),
 ('LU','Luxembourg','["luxembourg","luxemburgo"]',false),
 ('LV','Latvia','["latvia","letonia","letônia","lettonie"]',false),
 ('LY','Libya','["libya","libia","líbia","libye"]',false),
 ('MA','Morocco','["morocco","marruecos","marrocos","maroc"]',false),
 ('MC','Monaco','["monaco","mónaco","mônaco"]',false),
 ('MD','Moldova','["moldova","moldavia","moldávia","moldavie"]',false),
 ('ME','Montenegro','["montenegro","monténégro"]',false),
 ('MF','St. Martin','["st. martin","san martín","são martinho","saint-martin"]',false),
 ('MG','Madagascar','["madagascar"]',false),
 ('MH','Marshall Islands','["marshall islands","islas marshall","ilhas marshall","îles marshall"]',false),
 ('MK','North Macedonia','["north macedonia","macedonia del norte","macedônia do norte","macédoine du nord"]',false),
 ('ML','Mali','["mali"]',false),
 ('MM','Myanmar (Burma)','["myanmar (burma)","myanmar (birmania)","mianmar (birmânia)","myanmar (birmanie)"]',false),
 ('MN','Mongolia','["mongolia","mongólia","mongolie"]',false),
 ('MO','Macao SAR China','["macao sar china","rae de macao (china)","macau, rae da china","r.a.s. chinoise de macao"]',false),
 ('MP','Northern Mariana Islands','["northern mariana islands","islas marianas del norte","ilhas marianas do norte","îles mariannes du nord"]',false),
 ('MQ','Martinique','["martinique","martinica"]',false),
 ('MR','Mauritania','["mauritania","mauritânia","mauritanie"]',false),
 ('MS','Montserrat','["montserrat"]',false),
 ('MT','Malta','["malta","malte"]',false),
 ('MU','Mauritius','["mauritius","mauricio","maurício","maurice"]',false),
 ('MV','Maldives','["maldives","maldivas"]',false),
 ('MW','Malawi','["malawi","malaui"]',false),
 ('MX','Mexico','["mexico","méxico","mexique"]',false),
 ('MY','Malaysia','["malaysia","malasia","malásia","malaisie"]',false),
 ('MZ','Mozambique','["mozambique","moçambique"]',false),
 ('NA','Namibia','["namibia","namíbia","namibie"]',false),
 ('NC','New Caledonia','["new caledonia","nueva caledonia","nova caledônia","nouvelle-calédonie"]',false),
 ('NE','Niger','["niger","níger"]',false),
 ('NF','Norfolk Island','["norfolk island","isla norfolk","ilha norfolk","île norfolk"]',false),
 ('NG','Nigeria','["nigeria","nigéria"]',false),
 ('NI','Nicaragua','["nicaragua","nicarágua"]',false),
 ('NL','Netherlands','["netherlands","países bajos","países baixos","pays-bas","holanda"]',false),
 ('NO','Norway','["norway","noruega","norvège"]',false),
 ('NP','Nepal','["nepal","népal"]',false),
 ('NR','Nauru','["nauru"]',false),
 ('NU','Niue','["niue"]',false),
 ('NZ','New Zealand','["new zealand","nueva zelanda","nova zelândia","nouvelle-zélande"]',false),
 ('OM','Oman','["oman","omán","omã"]',false),
 ('PA','Panama','["panama","panamá"]',false),
 ('PE','Peru','["peru","perú","pérou"]',false),
 ('PF','French Polynesia','["french polynesia","polinesia francesa","polinésia francesa","polynésie française"]',false),
 ('PG','Papua New Guinea','["papua new guinea","papúa nueva guinea","papua-nova guiné","papouasie-nouvelle-guinée"]',false),
 ('PH','Philippines','["philippines","filipinas"]',false),
 ('PK','Pakistan','["pakistan","pakistán","paquistão"]',false),
 ('PL','Poland','["poland","polonia","polônia","pologne"]',false),
 ('PM','St. Pierre & Miquelon','["st. pierre & miquelon","san pedro y miquelón","são pedro e miquelão","saint-pierre-et-miquelon"]',false),
 ('PN','Pitcairn Islands','["pitcairn islands","islas pitcairn","ilhas pitcairn","îles pitcairn"]',false),
 ('PR','Puerto Rico','["puerto rico","porto rico"]',false),
 ('PS','Palestinian Territories','["palestinian territories","territorios palestinos","territórios palestinos","territoires palestiniens"]',false),
 ('PT','Portugal','["portugal"]',false),
 ('PW','Palau','["palau","palaos"]',false),
 ('PY','Paraguay','["paraguay","paraguai"]',false),
 ('QA','Qatar','["qatar","catar"]',false),
 ('RE','Réunion','["réunion","reunión","reunião","la réunion"]',false),
 ('RO','Romania','["romania","rumanía","romênia","roumanie"]',false),
 ('RS','Serbia','["serbia","sérvia","serbie"]',false),
 ('RU','Russia','["russia","rusia","rússia","russie"]',false),
 ('RW','Rwanda','["rwanda","ruanda"]',false),
 ('SA','Saudi Arabia','["saudi arabia","arabia saudí","arábia saudita","arabie saoudite"]',false),
 ('SB','Solomon Islands','["solomon islands","islas salomón","ilhas salomão","îles salomon"]',false),
 ('SC','Seychelles','["seychelles","seicheles"]',false),
 ('SD','Sudan','["sudan","sudán","sudão","soudan"]',false),
 ('SE','Sweden','["sweden","suecia","suécia","suède"]',false),
 ('SG','Singapore','["singapore","singapur","singapura","singapour"]',false),
 ('SH','St. Helena','["st. helena","santa elena","santa helena","sainte-hélène"]',false),
 ('SI','Slovenia','["slovenia","eslovenia","eslovênia","slovénie"]',false),
 ('SJ','Svalbard & Jan Mayen','["svalbard & jan mayen","svalbard y jan mayen","svalbard e jan mayen","svalbard et jan mayen"]',false),
 ('SK','Slovakia','["slovakia","eslovaquia","eslováquia","slovaquie"]',false),
 ('SL','Sierra Leone','["sierra leone","sierra leona","serra leoa"]',false),
 ('SM','San Marino','["san marino","saint-marin"]',false),
 ('SN','Senegal','["senegal","sénégal"]',false),
 ('SO','Somalia','["somalia","somália","somalie"]',false),
 ('SR','Suriname','["suriname","surinam"]',false),
 ('SS','South Sudan','["south sudan","sudán del sur","sudão do sul","soudan du sud"]',false),
 ('ST','São Tomé & Príncipe','["são tomé & príncipe","santo tomé y príncipe","são tomé e príncipe","sao tomé-et-principe"]',false),
 ('SV','El Salvador','["el salvador","salvador"]',false),
 ('SX','Sint Maarten','["sint maarten","saint-martin (partie néerlandaise)"]',false),
 ('SY','Syria','["syria","siria","síria","syrie"]',false),
 ('SZ','Eswatini','["eswatini","esuatini","essuatíni"]',false),
 ('TC','Turks & Caicos Islands','["turks & caicos islands","islas turcas y caicos","ilhas turcas e caicos","îles turques-et-caïques"]',false),
 ('TD','Chad','["chad","chade","tchad"]',false),
 ('TF','French Southern Territories','["french southern territories","territorios australes franceses","territórios franceses do sul","terres australes françaises"]',false),
 ('TG','Togo','["togo"]',false),
 ('TH','Thailand','["thailand","tailandia","tailândia","thaïlande"]',false),
 ('TJ','Tajikistan','["tajikistan","tayikistán","tadjiquistão","tadjikistan"]',false),
 ('TK','Tokelau','["tokelau"]',false),
 ('TL','Timor-Leste','["timor-leste","timor oriental"]',false),
 ('TM','Turkmenistan','["turkmenistan","turkmenistán","turcomenistão","turkménistan"]',false),
 ('TN','Tunisia','["tunisia","túnez","tunísia","tunisie"]',false),
 ('TO','Tonga','["tonga"]',false),
 ('TR','Türkiye','["türkiye","turquía","turquia","turquie","turkey"]',false),
 ('TT','Trinidad & Tobago','["trinidad & tobago","trinidad y tobago","trinidad e tobago","trinité-et-tobago"]',false),
 ('TV','Tuvalu','["tuvalu"]',false),
 ('TW','Taiwan','["taiwan","taiwán","taïwan"]',false),
 ('TZ','Tanzania','["tanzania","tanzânia","tanzanie"]',false),
 ('UA','Ukraine','["ukraine","ucrania","ucrânia"]',false),
 ('UG','Uganda','["uganda","ouganda"]',false),
 ('UM','U.S. Outlying Islands','["u.s. outlying islands","islas menores alejadas de ee. uu.","ilhas menores distantes dos eua","îles mineures éloignées des états-unis"]',false),
 ('US','United States','["united states","estados unidos","états-unis","usa","united states of america"]',false),
 ('UY','Uruguay','["uruguay","uruguai"]',false),
 ('UZ','Uzbekistan','["uzbekistan","uzbekistán","uzbequistão","ouzbékistan"]',false),
 ('VA','Vatican City','["vatican city","ciudad del vaticano","cidade do vaticano","état de la cité du vatican"]',false),
 ('VC','St. Vincent & Grenadines','["st. vincent & grenadines","san vicente y las granadinas","são vicente e granadinas","saint-vincent-et-les grenadines"]',false),
 ('VE','Venezuela','["venezuela"]',false),
 ('VG','British Virgin Islands','["british virgin islands","islas vírgenes británicas","ilhas virgens britânicas","îles vierges britanniques"]',false),
 ('VI','U.S. Virgin Islands','["u.s. virgin islands","islas vírgenes de ee. uu.","ilhas virgens americanas","îles vierges des états-unis"]',false),
 ('VN','Vietnam','["vietnam","vietnã","viêt nam"]',false),
 ('VU','Vanuatu','["vanuatu"]',false),
 ('WF','Wallis & Futuna','["wallis & futuna","wallis y futuna","wallis e futuna","wallis-et-futuna"]',false),
 ('WS','Samoa','["samoa"]',false),
 ('YE','Yemen','["yemen","iêmen","yémen"]',false),
 ('YT','Mayotte','["mayotte"]',false),
 ('ZA','South Africa','["south africa","sudáfrica","áfrica do sul","afrique du sud"]',false),
 ('ZM','Zambia','["zambia","zâmbia","zambie"]',false),
 ('ZW','Zimbabwe','["zimbabwe","zimbabue","zimbábue"]',false),
 ('GB-ENG','England','["england","inglaterra"]',false),
 ('GB-SCT','Scotland','["scotland","escocia"]',false),
 ('GB-WLS','Wales','["wales","gales"]',false),
 ('GB-NIR','Northern Ireland','["northern ireland","irlanda del norte"]',false),
 ('XK','Kosovo','["kosovo"]',false),
 ('EUROPE','Europe','["europe","uefa"]',true),
 ('SAMERICA','South America','["south america","conmebol"]',true),
 ('NAMERICA','North America','["north america"]',true),
 ('CAMERICA','Central America','["central america","concacaf"]',true),
 ('ASIA','Asia','["asia","afc"]',true),
 ('AFRICA','Africa','["africa","caf"]',true),
 ('OCEANIA','Oceania','["oceania","ofc"]',true),
 ('WORLD','World','["world","international"]',true)
on conflict(country_code) do update set canonical_name=excluded.canonical_name,
 aliases=excluded.aliases,is_supranational=excluded.is_supranational;

create table if not exists futbeat_private.competition_editorial_metadata(
  competition_id text primary key references futbeat_private.entities(id) on delete cascade,
  competition_class text not null check(competition_class in
    ('domestic_league','domestic_cup','international_club','international_national','other')),
  domestic_tier integer check(domestic_tier is null or domestic_tier between 1 and 20),
  is_primary_domestic boolean not null default false,
  audience_class text not null default 'unknown' check(audience_class in
    ('open','women','youth','reserve','amateur','unknown')),
  relevance_score integer not null default 100 check(relevance_score between 0 and 1000),
  is_global_relevant boolean not null default false,
  country_code text references futbeat_private.country_catalog(country_code),
  source text not null check(source in ('editorial','derived','provider')),
  updated_at timestamptz not null default now(),
  check(not is_primary_domestic or
    (competition_class='domestic_league' and domestic_tier=1 and audience_class='open'))
);
alter table futbeat_private.competition_editorial_metadata enable row level security;
revoke all on futbeat_private.competition_editorial_metadata from public,anon,authenticated;


-- Exact identity data, persisted for future ingestion, never substring guesses.
create table futbeat_private.competition_editorial_seed(
  seed_id bigint generated always as identity primary key,
  country_code text not null references futbeat_private.country_catalog(country_code),
  normalized_identity text not null,
  canonical_id text,
  provider text,
  provider_external_id text,
  competition_class text not null check(competition_class in
    ('domestic_league','domestic_cup','international_club','international_national','other')),
  domestic_tier integer,
  is_primary_domestic boolean not null default false,
  is_global_relevant boolean not null default false,
  audience_class text not null check(audience_class in
    ('open','women','youth','reserve','amateur','unknown')),
  relevance_score integer not null check(relevance_score between 0 and 1000),
  editorial_version integer not null default 1,
  unique(country_code,normalized_identity),
  check(not is_primary_domestic or
    (competition_class='domestic_league' and domestic_tier=1 and audience_class='open'))
);
alter table futbeat_private.competition_editorial_seed enable row level security;
revoke all on futbeat_private.competition_editorial_seed from public,anon,authenticated;

insert into futbeat_private.competition_editorial_seed(
 country_code,normalized_identity,competition_class,domestic_tier,is_primary_domestic,
 audience_class,relevance_score,is_global_relevant)
values
 ('EUROPE','champions league','international_club',null,false,'open',970,true),
 ('EUROPE','uefa champions league','international_club',null,false,'open',970,true),
 ('SAMERICA','copa libertadores','international_club',null,false,'open',950,true),
 ('SAMERICA','libertadores','international_club',null,false,'open',950,true),
 ('GB-ENG','premier league','domestic_league',1,true,'open',930,true),
 ('ES','laliga','domestic_league',1,true,'open',920,true),
 ('ES','la liga','domestic_league',1,true,'open',920,true),
 ('IT','serie a','domestic_league',1,true,'open',910,true),
 ('DE','bundesliga','domestic_league',1,true,'open',900,true),
 ('CR','liga promerica','domestic_league',1,true,'open',660,false),
 ('CR','primera división','domestic_league',1,true,'open',660,false);

-- Verified against the 500 stored canonical competitions on 2026-09-21.
-- Exact identities only. IDs below are existing catalog IDs, not new entities.
insert into futbeat_private.competition_editorial_seed(
 country_code,normalized_identity,canonical_id,competition_class,domestic_tier,
 is_primary_domestic,audience_class,relevance_score,is_global_relevant,editorial_version)
values
 ('GB-ENG','premier league','fb_competition_dfcf7ff6828b42c5a2d1bf452bc03f3a','domestic_league',1,true,'open',930,true,2),
 ('GB-ENG','championship','fb_competition_a9b61a532e9f44ea9c960bcbb2079b51','domestic_league',2,false,'open',520,false,2),
 ('ES','la liga','fb_competition_261d97ab29d549f7ae0eb34f7d25fb51','domestic_league',1,true,'open',920,true,2),
 ('ES','segunda división','fb_competition_1c70943052bb479ea7c3efad653f78e4','domestic_league',2,false,'open',500,false,2),
 ('IT','serie a','fb_competition_451f235752b944b4a135f17c16fecb60','domestic_league',1,true,'open',910,true,2),
 ('IT','serie b','fb_competition_a1722d5b34f64d40b3ee927eaedf87af','domestic_league',2,false,'open',480,false,2),
 ('DE','bundesliga','fb_competition_a42638fdc8004ce28d9f5e4d88d5f649','domestic_league',1,true,'open',900,true,2),
 ('DE','2. bundesliga','fb_competition_32310f42bc70471e9aef00251d929a81','domestic_league',2,false,'open',490,false,2),
 ('FR','ligue 1','fb_competition_c5f7436a7e954b8484d00b453fe3fcff','domestic_league',1,true,'open',890,true,2),
 ('FR','ligue 2','fb_competition_40d71d787cdd492a811a2d4c090028ee','domestic_league',2,false,'open',460,false,2),
 ('PT','primeira liga','fb_competition_bc851225b8804ec4b68dec0eaaf001d4','domestic_league',1,true,'open',810,false,2),
 ('NL','eredivisie','fb_competition_74650128391f49349ea491bf89066834','domestic_league',1,true,'open',800,false,2),
 ('BR','serie a','fb_competition_dc975afbf73c42129093807a55f48658','domestic_league',1,true,'open',860,true,2),
 ('BR','serie b','fb_competition_710832325804405489508456f63937ff','domestic_league',2,false,'open',450,false,2),
 ('AR','liga profesional argentina','fb_competition_4641dfb7d59846a8854007ddbc20a54a','domestic_league',1,true,'open',840,true,2),
 ('AR','primera nacional','fb_competition_1514e64327e1427f87b3420ce7a1e68f','domestic_league',2,false,'open',440,false,2),
 ('CO','primera a','fb_competition_593e52ab7de84645a83fc53264fef64f','domestic_league',1,true,'open',730,false,2),
 ('CL','primera división','fb_competition_a41207a9c806427480abafca3d335cee','domestic_league',1,true,'open',700,false,2),
 ('UY','primera división','fb_competition_162b7861ff3d419bb39a5972d86a0fa2','domestic_league',1,true,'open',690,false,2),
 ('MX','liga mx','fb_competition_de7c2e253e7c4d9f8ce991bfa4c472e2','domestic_league',1,true,'open',800,false,2),
 ('MX','liga de expansión mx','fb_competition_ef5a33ce4b444c8180f18658243e6c7d','domestic_league',2,false,'open',430,false,2),
 ('US','mls','fb_competition_7477e12b3ed54d5aa6475528ebc5f55d','domestic_league',1,true,'open',780,false,2),
 ('US','major league soccer','fb_competition_1f98eb3ba3ca43fba00a2cbc20b9a456','domestic_league',1,true,'open',780,false,2),
 ('CA','canadian premier league','fb_competition_23e6d53c646e45de917573787a651d0f','domestic_league',1,true,'open',620,false,2),
 ('CR','primera división','fb_competition_3e03182862764420947393642a407616','domestic_league',1,true,'open',660,false,2),
 ('CR','primera division','fb_competition_0c2ab7abd95d4c08923e66d3752bfe9f','domestic_league',1,true,'open',660,false,2),
 ('CR','costa-rica liga fpd','fb_comp_cr','domestic_league',1,true,'open',660,false,2),
 ('CR','liga de ascenso','fb_competition_bb87bbb7ef054e76abd8c947a1582619','domestic_league',2,false,'open',250,false,2),
 ('JP','j1 league','fb_competition_4b0c70637e32410e9420306ddc206a09','domestic_league',1,true,'open',720,false,2),
 ('JP','j2 league','fb_competition_d92c1b3bd9c048deb5c37ae12189ef2f','domestic_league',2,false,'open',400,false,2),
 ('KR','k league 1','fb_competition_565a888423fd4b65a264cc9590ac0607','domestic_league',1,true,'open',700,false,2),
 ('AU','a-league men','fb_competition_c3e408deb095483684d9c8410b5846ef','domestic_league',1,true,'open',680,false,2),
 ('EG','premier league','fb_competition_7a8572e652b945e6976a79d04dca1ab3','domestic_league',1,true,'open',690,false,2),
 ('MA','botola pro','fb_competition_a161d6adf12a4f1cafe1e7f53d1c3b3b','domestic_league',1,true,'open',680,false,2),
 ('DZ','ligue 1','fb_competition_a76a1eefcea04ed5bca3b60c71bdcb11','domestic_league',1,true,'open',660,false,2),
 ('TN','ligue 1','fb_competition_b41f55e2034d4a6a9d2a73d76e44fc63','domestic_league',1,true,'open',650,false,2),
 ('EUROPE','uefa champions league','fb_competition_c29b41f44f014949934f4aa39f5b2117','international_club',null,false,'open',970,true,2),
 ('EUROPE','uefa europa league','fb_competition_e5c29f3ae71c4f50b58238fc5f24cdfa','international_club',null,false,'open',940,true,2),
 ('EUROPE','uefa conference league','fb_competition_2c0aa9b0a2ab4f45a6a168edcac1b15d','international_club',null,false,'open',900,true,2),
 ('SAMERICA','conmebol libertadores','fb_competition_04671e30b6024249a0ece234a789d12a','international_club',null,false,'open',950,true,2),
 ('SAMERICA','conmebol sudamericana','fb_competition_03c34247add94e35966572b02c72a307','international_club',null,false,'open',890,true,2),
 ('EUROPE','uefa nations league','fb_competition_9343d6566e944641a424244d0f7b9233','international_national',null,false,'open',910,true,2),
 ('CAMERICA','concacaf nations league','fb_competition_31afb39e74cb4e4da5e2d59f254d421d','international_national',null,false,'open',760,false,2),
 ('GB-ENG','fa cup','fb_competition_e04b07f772d34faeb3ec836a4fe03299','domestic_cup',null,false,'open',820,false,2),
 ('ES','copa del rey','fb_competition_ec903d96259f4453abef9503291eda27','domestic_cup',null,false,'open',810,false,2),
 ('IT','coppa italia','fb_competition_7afabc7632d14fa5b580b5e47d900e03','domestic_cup',null,false,'open',800,false,2),
 ('DE','dfb pokal','fb_competition_f09c557314304ff28a5ee6b60df35919','domestic_cup',null,false,'open',790,false,2),
 ('BR','copa do brasil','fb_competition_e943d5be8273406cb651f3c24cfee373','domestic_cup',null,false,'open',780,false,2),
 ('AR','copa argentina','fb_competition_82b199c9325a4e3099407b9599dc2b08','domestic_cup',null,false,'open',740,false,2)
on conflict(country_code,normalized_identity) do update set
 canonical_id=excluded.canonical_id,competition_class=excluded.competition_class,
 domestic_tier=excluded.domestic_tier,is_primary_domestic=excluded.is_primary_domestic,
 audience_class=excluded.audience_class,relevance_score=excluded.relevance_score,
 is_global_relevant=excluded.is_global_relevant,editorial_version=excluded.editorial_version;

create or replace function futbeat_private.resolve_country_code(p_country text)
returns text language sql stable security invoker set search_path='' as $$
 select c.country_code from futbeat_private.country_catalog c
 where c.country_code=upper(trim(p_country))
    or lower(c.canonical_name)=lower(trim(p_country))
    or c.aliases @> jsonb_build_array(lower(trim(p_country)))
 order by (c.country_code=upper(trim(p_country))) desc,c.country_code limit 1
$$;

create or replace function futbeat_private.safe_result_integer(p_value text)
returns integer language plpgsql immutable security invoker set search_path='' as $$
begin
 if p_value is null or p_value !~ '^[0-9]{1,9}$' then return null; end if;
 return p_value::integer;
end $$;


-- Canonical minutes are integer/null. Raw provider observations stay untouched.
create or replace function futbeat_private.normalize_event_minutes(p_event jsonb)
returns jsonb language plpgsql immutable security invoker set search_path='' as $$
declare v_text text:=trim(p_event->>'minute'); v_minute integer; v_extra integer;
begin
 if jsonb_typeof(p_event)<>'object' then return p_event; end if;
 if v_text ~ '^[0-9]{1,9}([+][0-9]{1,9})?$' then
   v_minute:=futbeat_private.safe_result_integer(split_part(v_text,'+',1));
   v_extra:=case when position('+' in v_text)>0
     then futbeat_private.safe_result_integer(split_part(v_text,'+',2))
     else futbeat_private.safe_result_integer(p_event->>'extraMinute') end;
 end if;
 return p_event||jsonb_build_object('minute',v_minute,'extraMinute',v_extra);
end $$;

create or replace function futbeat_private.normalize_event_array(p_events jsonb)
returns jsonb language sql immutable security invoker set search_path='' as $$
 select coalesce(jsonb_agg(futbeat_private.normalize_event_minutes(item) order by ordinal),'[]'::jsonb)
 from jsonb_array_elements(case when jsonb_typeof(p_events)='array'
   then p_events else '[]'::jsonb end) with ordinality as events(item,ordinal)
$$;

create or replace function futbeat_private.normalize_canonical_event_contract()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if tg_table_name='canonical_events' then
   new.payload:=futbeat_private.normalize_event_minutes(new.payload);
 elsif tg_table_name='entities' then
   if new.kind='match' and jsonb_typeof(new.payload->'events')='array' then
     new.payload:=jsonb_set(new.payload,'{events}',futbeat_private.normalize_event_array(new.payload->'events'));
   end if;
 elsif jsonb_typeof(new.payload->'events')='array' then
   new.payload:=jsonb_set(new.payload,'{events}',futbeat_private.normalize_event_array(new.payload->'events'));
 end if;
 return new;
end $$;

create trigger futbeat_normalize_event_minutes before insert or update of payload
on futbeat_private.canonical_events for each row
execute function futbeat_private.normalize_canonical_event_contract();
create trigger futbeat_normalize_match_event_minutes before insert or update of payload
on futbeat_private.entities for each row
execute function futbeat_private.normalize_canonical_event_contract();
create trigger futbeat_normalize_detail_event_minutes before insert or update of payload
on futbeat_private.match_detail_cache for each row
execute function futbeat_private.normalize_canonical_event_contract();

-- One-time repair of stored projections, never raw provider data.
update futbeat_private.canonical_events
 set payload=futbeat_private.normalize_event_minutes(payload)
 where payload is distinct from futbeat_private.normalize_event_minutes(payload);
update futbeat_private.entities
 set payload=jsonb_set(payload,'{events}',futbeat_private.normalize_event_array(payload->'events'))
 where kind='match' and jsonb_typeof(payload->'events')='array'
   and payload->'events' is distinct from futbeat_private.normalize_event_array(payload->'events');
update futbeat_private.match_detail_cache
 set payload=jsonb_set(payload,'{events}',futbeat_private.normalize_event_array(payload->'events'))
 where jsonb_typeof(payload->'events')='array'
   and payload->'events' is distinct from futbeat_private.normalize_event_array(payload->'events');

create or replace function futbeat_private.sync_competition_metadata()
returns trigger language plpgsql security invoker set search_path='' as $$
declare v_code text; v_supra boolean; v_class text; v_audience text; v_seed record;
begin
 if new.kind<>'competition' then return new; end if;
 if exists(select 1 from futbeat_private.competition_editorial_metadata
   where competition_id=new.id and source='editorial') then return new; end if;
 v_code:=coalesce(futbeat_private.resolve_country_code(new.payload->>'country'),
   futbeat_private.resolve_country_code(new.payload->>'countryCode'));
 select is_supranational into v_supra from futbeat_private.country_catalog where country_code=v_code;
 v_audience:=case when new.payload->>'audienceClass' in
   ('open','women','youth','reserve','amateur') then new.payload->>'audienceClass' else 'unknown' end;
 select seed.* into v_seed from futbeat_private.competition_editorial_seed seed
 where (seed.canonical_id=new.id or
   (seed.country_code=v_code and seed.normalized_identity=lower(trim(new.payload->>'name'))) or
   exists(select 1 from futbeat_private.provider_entities pe
     where pe.kind='competition' and pe.canonical_id=new.id
       and pe.provider=seed.provider and pe.external_id=seed.provider_external_id))
   and (v_audience='unknown' or v_audience=seed.audience_class)
 order by (seed.canonical_id=new.id) desc nulls last,seed.seed_id limit 1;
 v_class:=case when new.payload->>'competitionClass' in
   ('domestic_league','domestic_cup','international_club','international_national','other')
   then new.payload->>'competitionClass'
   when coalesce(v_supra,false) then 'international_club' else 'other' end;
 -- Region determines scope only. Provider global flags are not trusted until
 -- explicitly curated; all noneditorial metadata has is_global_relevant=false.
 insert into futbeat_private.competition_editorial_metadata(
   competition_id,competition_class,domestic_tier,is_primary_domestic,audience_class,
   relevance_score,is_global_relevant,country_code,source)
 values(new.id,coalesce(v_seed.competition_class,v_class),v_seed.domestic_tier,
   coalesce(v_seed.is_primary_domestic,false),coalesce(v_seed.audience_class,v_audience),
   coalesce(v_seed.relevance_score,least(1000,coalesce(futbeat_private.safe_result_integer(new.payload->>'relevanceScore'),100))),
   coalesce(v_seed.is_global_relevant,false),coalesce(v_seed.country_code,v_code),
   case when v_seed.seed_id is not null then 'editorial'
     when new.payload->>'competitionClass'=v_class or v_audience<>'unknown' then 'provider' else 'derived' end)
 on conflict(competition_id) do update set
   competition_class=excluded.competition_class,domestic_tier=excluded.domestic_tier,
   is_primary_domestic=excluded.is_primary_domestic,audience_class=excluded.audience_class,
   relevance_score=excluded.relevance_score,is_global_relevant=excluded.is_global_relevant,
   country_code=excluded.country_code,source=excluded.source,updated_at=now()
 where futbeat_private.competition_editorial_metadata.source<>'editorial'
   and (futbeat_private.competition_editorial_metadata.competition_class,
        futbeat_private.competition_editorial_metadata.audience_class,
        futbeat_private.competition_editorial_metadata.relevance_score,
        futbeat_private.competition_editorial_metadata.country_code,
        futbeat_private.competition_editorial_metadata.source,
        futbeat_private.competition_editorial_metadata.is_global_relevant)
     is distinct from (excluded.competition_class,excluded.audience_class,
       excluded.relevance_score,excluded.country_code,excluded.source,excluded.is_global_relevant);
 return new;
end $$;

create trigger futbeat_sync_competition_metadata after insert or update of payload
on futbeat_private.entities for each row execute function futbeat_private.sync_competition_metadata();
-- One required backfill: materialize metadata for preexisting canonical identities.
update futbeat_private.entities set payload=payload where kind='competition';

create table if not exists futbeat_private.results_date_attempts(
  provider text not null,
  provider_date date not null,
  last_attempt_at timestamptz,
  attempt_count integer not null default 0 check(attempt_count>=0),
  last_outcome text not null default 'PENDING' check(last_outcome in
    ('PENDING','RESERVED','SUCCEEDED','FAILED','PARTIAL','LOCAL_REPAIRED','CLOSED_MISSING','QUOTA_DEFERRED')),
  next_retry_at timestamptz not null default now(),
  last_result_count integer not null default 0 check(last_result_count>=0),
  last_unmatched_count integer not null default 0 check(last_unmatched_count>=0),
  updated_at timestamptz not null default now(),
  primary key(provider,provider_date)
);
alter table futbeat_private.results_date_attempts enable row level security;
revoke all on futbeat_private.results_date_attempts from public,anon,authenticated;
-- Reuse calendar_matches_start_time_idx from calendar_range_catalog.
create index if not exists provider_observations_canonical_received_idx
  on futbeat_private.provider_observations(provider,canonical_match_id,received_at desc,id desc)
  where canonical_match_id is not null;

create table if not exists futbeat_private.match_result_reconciliation(
  match_id text primary key references futbeat_private.entities(id) on delete cascade,
  state text not null check(state in
    ('resolved','unresolved','missing_from_provider','rescheduled','ignored_noncanonical')),
  provider text not null,
  provider_date date not null,
  evidence_at timestamptz,
  canonical_payload_hash text check(canonical_payload_hash is null or canonical_payload_hash ~ '^[0-9a-f]{32}$'),
  updated_at timestamptz not null default now()
);
alter table futbeat_private.match_result_reconciliation enable row level security;
revoke all on futbeat_private.match_result_reconciliation from public,anon,authenticated;
create index if not exists match_result_reconciliation_date_idx
  on futbeat_private.match_result_reconciliation(provider,provider_date,state);

create or replace function futbeat_private.reconcile_goal_results_local(p_provider_date date)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare r record; v_original jsonb; v_payload jsonb; v_events jsonb;
  v_changed integer:=0; v_events_changed integer:=0; v_state text;
  v_complete boolean; v_kickoff timestamptz; v_canonical_at timestamptz;
  v_attempts integer;
begin
  if p_provider_date is null then raise exception 'Invalid result date'; end if;
  select coalesce(a.attempt_count,0) into v_attempts
    from (select 1) seed left join futbeat_private.results_date_attempts a
      on a.provider='goal_api' and a.provider_date=p_provider_date;
  for r in
    select cm.match_id,cm.start_time,cm.updated_at as calendar_updated_at,o.status,o.minute,o.home_score,o.away_score,
      o.received_at,o.provider_observed_at,o.raw_payload
    from futbeat_private.calendar_matches cm
    left join lateral (
      select observation.* from futbeat_private.provider_observations observation
      where observation.provider='goal_api' and observation.canonical_match_id=cm.match_id
      order by observation.received_at desc,observation.id desc limit 1
    ) o on true
    where cm.start_time>=p_provider_date::timestamp at time zone 'UTC'
      and cm.start_time<(p_provider_date+1)::timestamp at time zone 'UTC'
  loop
    select payload into v_original from futbeat_private.entities
      where id=r.match_id and kind='match' for update;
    if v_original is null then continue; end if;
    v_payload:=v_original;
    select coalesce(jsonb_agg(payload order by
      coalesce(futbeat_private.safe_result_integer(payload->>'minute'),-1),
      coalesce(futbeat_private.safe_result_integer(payload->>'extraMinute'),0),first_seen_at,id),'[]'::jsonb)
      into v_events from futbeat_private.canonical_events where match_id=r.match_id;
    if jsonb_array_length(v_events)>0
       and coalesce(v_payload->'events','[]'::jsonb) is distinct from v_events then
      v_payload:=jsonb_set(v_payload,'{events}',v_events,true);
      v_events_changed:=v_events_changed+1;
    end if;
    v_canonical_at:=coalesce(
      futbeat_private.try_timestamptz(v_payload#>>'{provenance,receivedAt}'),
      r.calendar_updated_at);
    v_kickoff:=futbeat_private.try_timestamptz(r.raw_payload->>'kickoffUtc');
    if r.received_at is not null
       and coalesce(r.provider_observed_at,r.received_at)>=v_canonical_at then
      if v_payload->>'status' not in ('VERIFIED','FINISHED_PENDING_VERIFICATION','CANCELLED')
         and v_kickoff is not null and v_kickoff is distinct from
         futbeat_private.try_timestamptz(v_payload->>'startTime') then
        v_payload:=jsonb_set(v_payload,'{startTime}',to_jsonb(v_kickoff),true);
      end if;
      if coalesce(v_payload->>'status','') not in ('VERIFIED','FINISHED_PENDING_VERIFICATION','CANCELLED')
         and (
           r.status in ('VERIFIED','FINISHED_PENDING_VERIFICATION','POSTPONED','CANCELLED','SUSPENDED','ABANDONED')
           or (r.status in ('SCHEDULED','PRE_MATCH','LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
             and v_payload->>'status' in ('POSTPONED','SUSPENDED','ABANDONED')
             and (r.status not in ('SCHEDULED','PRE_MATCH') or v_kickoff is not null))
         ) then
        v_payload:=v_payload||jsonb_strip_nulls(jsonb_build_object(
          'status',r.status,
          'score',case when r.home_score is not null and r.away_score is not null
            then jsonb_build_object('home',r.home_score,'away',r.away_score)
            else v_payload->'score' end,
          'minute',coalesce(to_jsonb(r.minute),v_payload->'minute'),
          'provenance',coalesce(v_payload->'provenance','{}'::jsonb)||jsonb_build_object(
            'receivedAt',r.received_at,'verificationStatus','VERIFIED','reconciledLocally',true)
        ));
      elsif v_payload->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
        and r.status in ('FINISHED_PENDING_VERIFICATION','VERIFIED') then
        -- A final score can be corrected by newer real evidence, but finished
        -- status never regresses and CANCELLED remains a strong terminal state.
        v_payload:=v_payload||jsonb_strip_nulls(jsonb_build_object(
          'status',case when v_payload->>'status'='VERIFIED' or r.status='VERIFIED'
            then 'VERIFIED' else 'FINISHED_PENDING_VERIFICATION' end,
          'score',case when r.home_score is not null and r.away_score is not null
            then jsonb_build_object('home',r.home_score,'away',r.away_score)
            else v_payload->'score' end));
        if v_payload is distinct from v_original then
          v_payload:=jsonb_set(v_payload,'{provenance}',
            coalesce(v_payload->'provenance','{}'::jsonb)||jsonb_build_object(
              'receivedAt',r.received_at,'reconciledLocally',true),true);
        end if;
      end if;
    end if;
    if v_payload is distinct from v_original then
      update futbeat_private.entities set payload=v_payload where id=r.match_id;
      v_changed:=v_changed+1;
    end if;
    v_state:=case
      when (futbeat_private.try_timestamptz(v_payload->>'startTime') at time zone 'UTC')::date<>p_provider_date
        then 'rescheduled'
      when v_payload->>'status' in
        ('VERIFIED','FINISHED_PENDING_VERIFICATION','POSTPONED','CANCELLED','SUSPENDED','ABANDONED')
        then 'resolved'
      when v_attempts>=4 and r.start_time<now()-interval '48 hours'
        then 'missing_from_provider'
      else 'unresolved' end;
    insert into futbeat_private.match_result_reconciliation(
      match_id,state,provider,provider_date,evidence_at,canonical_payload_hash,updated_at)
    values(r.match_id,v_state,'goal_api',p_provider_date,r.received_at,md5(v_payload::text),now())
    on conflict(match_id) do update set state=excluded.state,provider_date=excluded.provider_date,
      evidence_at=excluded.evidence_at,canonical_payload_hash=excluded.canonical_payload_hash,updated_at=excluded.updated_at
    where (futbeat_private.match_result_reconciliation.state,
           futbeat_private.match_result_reconciliation.provider_date,
           futbeat_private.match_result_reconciliation.evidence_at,
           futbeat_private.match_result_reconciliation.canonical_payload_hash)
       is distinct from (excluded.state,excluded.provider_date,excluded.evidence_at,excluded.canonical_payload_hash);
  end loop;
  select not exists(select 1 from futbeat_private.match_result_reconciliation mr
    where mr.provider='goal_api' and mr.provider_date=p_provider_date and mr.state='unresolved')
    into v_complete;
  update futbeat_private.calendar_coverage set results_complete=v_complete,
    results_checked_at=now() where provider='goal_api' and provider_date=p_provider_date
      and results_complete is distinct from v_complete;
  return jsonb_build_object('date',p_provider_date,'updated',v_changed,
    'eventsUpdated',v_events_changed,'resultsComplete',v_complete,
    'unresolved',(select count(*) from futbeat_private.match_result_reconciliation mr
      where mr.provider='goal_api' and mr.provider_date=p_provider_date and mr.state='unresolved'));
end $$;


-- Closed dates are excluded by absence of work, never by an irreversible deadline.
-- New evidence bypasses a completed closure, but not an active quota/provider cooldown.
create or replace function futbeat_private.next_goal_results_candidate()
returns date language sql stable security invoker set search_path='' as $$
 with candidates as (
   select distinct (cm.start_time at time zone 'UTC')::date provider_date
   from futbeat_private.calendar_matches cm
   join futbeat_private.entities e on e.id=cm.match_id and e.kind='match'
   left join futbeat_private.match_result_reconciliation mr on mr.match_id=cm.match_id
   where cm.start_time>=((now() at time zone 'UTC')::date-14)::timestamp at time zone 'UTC'
     and cm.start_time<((now() at time zone 'UTC')::date)::timestamp at time zone 'UTC'
     and (mr.match_id is null or mr.state='unresolved'
       or mr.canonical_payload_hash is distinct from md5(e.payload::text)
       or mr.provider_date<>(cm.start_time at time zone 'UTC')::date
       or exists(select 1 from futbeat_private.provider_observations o
         where o.provider='goal_api' and o.canonical_match_id=cm.match_id
           and o.received_at>coalesce(mr.evidence_at,'-infinity'::timestamptz))
       or exists(select 1 from futbeat_private.canonical_events ce
         where ce.match_id=cm.match_id and not coalesce(e.payload->'events','[]'::jsonb)
           @> jsonb_build_array(ce.payload)))
 )
 select c.provider_date from candidates c
 left join futbeat_private.results_date_attempts a
   on a.provider='goal_api' and a.provider_date=c.provider_date
 where a.next_retry_at is null or a.next_retry_at<=now()
 order by coalesce(a.attempt_count,0),coalesce(a.last_attempt_at,'epoch'::timestamptz),
   c.provider_date desc limit 1
$$;

create or replace function futbeat_private.results_retry_delay(p_date date,p_attempt integer)
returns interval language sql stable security invoker set search_path='' as $$
  select (case when p_date>=(now() at time zone 'UTC')::date-2
    then interval '2 hours' else interval '6 hours' end)
    * least(greatest(p_attempt,1),4)
$$;

create or replace function futbeat_private.reserve_goal_results_date(
  p_trigger_source text default 'supabase-cron'
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_date date; v_id bigint; v_remaining integer; v_used integer;
  v_results_used integer; v_local jsonb; v_attempt integer;
begin
  perform pg_advisory_xact_lock(hashtext('futbeat-provider-quota:goal_api:'||(now() at time zone 'UTC')::date::text));
  -- Retain 90 days, well beyond the 14-day automatic window. Primary key
  -- supports deletion by provider/date; old evidence remains in observations.
  delete from futbeat_private.results_date_attempts
    where provider='goal_api' and provider_date<(now() at time zone 'UTC')::date-90;
  -- Indexed by (provider,provider_date,state); never scans JSON.
  delete from futbeat_private.match_result_reconciliation
    where provider='goal_api' and provider_date<(now() at time zone 'UTC')::date-90;
  v_date:=futbeat_private.next_goal_results_candidate();
  if v_date is null then return jsonb_build_object('allowed',false,'reason','no_results_due'); end if;
  v_local:=futbeat_private.reconcile_goal_results_local(v_date);
  if coalesce((v_local->>'resultsComplete')::boolean,false) then
    insert into futbeat_private.results_date_attempts(provider,provider_date,last_outcome,next_retry_at,updated_at)
    values('goal_api',v_date,'LOCAL_REPAIRED',now(),now())
    on conflict(provider,provider_date) do update set last_outcome='LOCAL_REPAIRED',
      next_retry_at=now(),updated_at=now();
    return jsonb_build_object('allowed',false,'reason','reconciled_locally','date',v_date,'localRepair',v_local);
  end if;
  select provider_remaining into v_remaining from futbeat_private.provider_call_ledger
    where provider='goal_api' and provider_remaining is not null
      and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'
    order by coalesce(completed_at,reserved_at) desc,id desc limit 1;
  select coalesce(sum(case when status='SUCCEEDED' then greatest(
    coalesce((metadata->>'providerRequests')::integer,1),1) else 1 end),0)::integer
    into v_used from futbeat_private.provider_call_ledger where provider='goal_api'
      and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  select count(*)::integer into v_results_used from futbeat_private.provider_call_ledger
    where provider='goal_api' and call_kind='results-date'
      and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  if v_results_used>=60 or v_used>=880 or (v_remaining is not null and v_remaining<=120) then
    insert into futbeat_private.results_date_attempts(provider,provider_date,last_outcome,next_retry_at)
    values('goal_api',v_date,'QUOTA_DEFERRED',now()+interval '30 minutes')
    on conflict(provider,provider_date) do update set last_outcome='QUOTA_DEFERRED',
      next_retry_at=now()+interval '30 minutes',updated_at=now();
    return jsonb_build_object('allowed',false,'reason','results_quota_guard','localRepair',v_local,
      'usedToday',v_used,'resultsUsedToday',v_results_used,'providerRemaining',v_remaining);
  end if;
  insert into futbeat_private.results_date_attempts(
    provider,provider_date,last_attempt_at,attempt_count,last_outcome,next_retry_at,updated_at)
  values('goal_api',v_date,now(),1,'RESERVED',now()+futbeat_private.results_retry_delay(v_date,1),now())
  on conflict(provider,provider_date) do update set last_attempt_at=now(),
    attempt_count=futbeat_private.results_date_attempts.attempt_count+1,
    last_outcome='RESERVED',next_retry_at=now()+futbeat_private.results_retry_delay(
      v_date,futbeat_private.results_date_attempts.attempt_count+1),updated_at=now()
  returning attempt_count into v_attempt;
  insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata)
  values('goal_api','results-date',left(p_trigger_source,40),now(),
    jsonb_build_object('date',v_date,'attempt',v_attempt)) returning id into v_id;
  return jsonb_build_object('allowed',true,'reservationId',v_id,'date',v_date,
    'attempt',v_attempt,'localRepair',v_local,'providerRemaining',v_remaining);
end $$;

create or replace function futbeat_private.complete_results_date_attempt(
  p_provider_date date,p_outcome text,p_result_count integer,p_unmatched_count integer
) returns void language plpgsql security invoker set search_path='' as $$
begin
  if p_outcome not in ('SUCCEEDED','FAILED','PARTIAL') then raise exception 'Invalid outcome'; end if;
  update futbeat_private.results_date_attempts set last_outcome=p_outcome,
    last_result_count=greatest(coalesce(p_result_count,0),0),
    last_unmatched_count=greatest(coalesce(p_unmatched_count,0),0),updated_at=now(),
    next_retry_at=case when p_outcome='SUCCEEDED' then next_retry_at
      else now()+futbeat_private.results_retry_delay(provider_date,attempt_count+1) end
  where provider='goal_api' and provider_date=p_provider_date;
end $$;

create or replace function public.futbeat_complete_results_date_attempt(
  p_provider_date date,p_outcome text,p_result_count integer,p_unmatched_count integer
) returns void language sql security definer set search_path='' as $$
 select futbeat_private.complete_results_date_attempt(
   p_provider_date,p_outcome,p_result_count,p_unmatched_count) $$;

revoke all on function futbeat_private.complete_results_date_attempt(date,text,integer,integer),
 public.futbeat_complete_results_date_attempt(date,text,integer,integer)
from public,anon,authenticated;
grant execute on function public.futbeat_complete_results_date_attempt(date,text,integer,integer)
to service_role;

create or replace function public.futbeat_read_calendar_range(
  p_from_date date,p_to_date date,
  p_timezone text default 'America/Costa_Rica'
) returns jsonb language sql stable security definer set search_path='' as $$
  with source as materialized (
    select futbeat_private.futbeat_apply_entity_redirects_snapshot(
      futbeat_private.futbeat_read_calendar_range(p_from_date,p_to_date,p_timezone)
    ) value
  ), team_countries as materialized (
    select country,futbeat_private.resolve_country_code(country) as code
    from (select distinct item->>'country' country from source
      cross join lateral jsonb_array_elements(coalesce(source.value->'teams','[]'::jsonb)) item) names
  ), compact_teams as (
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id',item->'id','name',item->'name','shortName',item->'shortName',
      'country',item->'country','countryCode',to_jsonb(coalesce(
        item->>'countryCode',countries.code)),
      'competitionId',item->'competitionId',
      'media',case when item->'media' is null then null else jsonb_strip_nulls(
        jsonb_build_object('url',item#>'{media,url}','verificationStatus',
          item#>'{media,verificationStatus}')) end
    )) order by item->>'name',item->>'id'),'[]'::jsonb) value
    from source cross join lateral jsonb_array_elements(
      coalesce(source.value->'teams','[]'::jsonb)) item
    left join team_countries countries on countries.country=item->>'country'
  ), compact_competitions as (
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id',item->'id','name',item->'name','country',item->'country',
      'countryCode',to_jsonb(coalesce(meta.country_code,item->>'countryCode')),
      'relevanceScore',to_jsonb(coalesce(meta.relevance_score,
        futbeat_private.safe_result_integer(item->>'relevanceScore'),100)),
      'competitionClass',to_jsonb(coalesce(meta.competition_class,
        item->>'competitionClass','other')),
      'domesticTier',to_jsonb(meta.domestic_tier),
      'isPrimaryDomestic',to_jsonb(coalesce(meta.is_primary_domestic,false)),
      'isGlobalRelevant',to_jsonb(coalesce(meta.is_global_relevant,false)),
      'audienceClass',to_jsonb(coalesce(meta.audience_class,'unknown')),
      'relevanceSource',to_jsonb(coalesce(meta.source,'derived')),
      'media',case when item->'media' is null then null else jsonb_strip_nulls(
        jsonb_build_object('url',item#>'{media,url}','verificationStatus',
          item#>'{media,verificationStatus}')) end
    )) order by item->>'country',item->>'name',item->>'id'),'[]'::jsonb) value
    from source cross join lateral jsonb_array_elements(
      coalesce(source.value->'competitions','[]'::jsonb)) item
    left join futbeat_private.competition_editorial_metadata meta
      on meta.competition_id=item->>'id'
  ), compact_matches as (
    select coalesce(jsonb_agg((jsonb_strip_nulls(jsonb_build_object(
      'id',item->'id','competitionId',item->'competitionId',
      'homeTeamId',item->'homeTeamId','awayTeamId',item->'awayTeamId',
      'startTime',item->'startTime','status',item->'status','score',item->'score',
      'minute',item->'minute',
      'statistics',coalesce(item->'statistics','[]'::jsonb),
      'venue',item->'venue','season',item->'season',
      'provenance',case when item->'provenance' is null then null
        else jsonb_strip_nulls(jsonb_build_object(
          'source',item#>'{provenance,source}',
          'receivedAt',item#>'{provenance,receivedAt}')) end
    ))||jsonb_build_object('events',futbeat_private.normalize_event_array(item->'events')))
      order by item->>'startTime',item->>'id'),'[]'::jsonb) value
    from source cross join lateral jsonb_array_elements(
      coalesce(source.value->'matches','[]'::jsonb)) item
  )
  select (source.value-'teams'-'competitions'-'matches')||jsonb_build_object(
    'teams',compact_teams.value,'competitions',compact_competitions.value,
    'matches',compact_matches.value)
  from source,compact_teams,compact_competitions,compact_matches
$$;
revoke all on function public.futbeat_read_calendar_range(date,date,text)
  from public,anon,authenticated;
grant execute on function public.futbeat_read_calendar_range(date,date,text) to service_role;

-- Service-only wrappers; local repair also supports an explicit older date.
create or replace function public.futbeat_reconcile_goal_results_local(p_provider_date date)
returns jsonb language sql security definer set search_path='' as $$
 select futbeat_private.reconcile_goal_results_local(p_provider_date) $$;
create or replace function public.futbeat_next_goal_results_candidate()
returns date language sql security definer set search_path='' as $$
 select futbeat_private.next_goal_results_candidate() $$;

-- Both batch finalization and free repair share the same freshness policy.
create or replace function futbeat_private.finalize_goal_results_date(
 p_provider_date date,p_received_at timestamptz
) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if p_received_at is null then raise exception 'Invalid result batch'; end if;
 return futbeat_private.reconcile_goal_results_local(p_provider_date);
end $$;

revoke all on function
 futbeat_private.normalize_event_minutes(jsonb),
 futbeat_private.normalize_event_array(jsonb),
 futbeat_private.normalize_canonical_event_contract(),
 futbeat_private.try_timestamptz(text),
 futbeat_private.competition_relevance_score(text,text),
 futbeat_private.apply_competition_relevance(),
 futbeat_private.preserve_verified_player_media(),
 futbeat_private.track_player_media_coverage(),
 futbeat_private.resolve_country_code(text),
 futbeat_private.safe_result_integer(text),
 futbeat_private.sync_competition_metadata(),
 futbeat_private.results_retry_delay(date,integer),
 futbeat_private.reconcile_goal_results_local(date),
 futbeat_private.next_goal_results_candidate(),
 futbeat_private.reserve_goal_results_date(text),
 futbeat_private.finalize_goal_results_date(date,timestamptz),
 public.futbeat_reconcile_goal_results_local(date),
 public.futbeat_next_goal_results_candidate()
from public,anon,authenticated;
grant execute on function public.futbeat_reconcile_goal_results_local(date),
 public.futbeat_next_goal_results_candidate() to service_role;

notify pgrst,'reload schema';
