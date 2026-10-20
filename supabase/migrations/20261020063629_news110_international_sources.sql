-- NEWS110: candidate feeds only. Discovery is not permission to republish.
-- Every feed remains disabled; publisher/provider rights remain false.
alter table futbeat_private.news_feeds
  add column if not exists coverage_country_code text
    check (coverage_country_code is null or coverage_country_code ~ '^[A-Z]{2}$'),
  add column if not exists language_code text
    check (language_code is null or language_code ~ '^[a-z]{2}$');

insert into futbeat_private.news_sources
  (domain,display_name,role,country_code,notes) values
  ('as.com','AS','ESTABLISHED_MEDIA','ES','Official football RSS index verified; commercial reuse and content rights unreviewed'),
  ('clarin.com','Clarín','ESTABLISHED_MEDIA','AR','Official football RSS index verified; commercial reuse and content rights unreviewed'),
  ('ge.globo.com','ge Globo','ESTABLISHED_MEDIA','BR','Official RSS index verified; endpoint is legacy and requires recheck before enablement'),
  ('eltiempo.com','El Tiempo','ESTABLISHED_MEDIA','CO','Official Colombian football RSS index verified; commercial reuse and content rights unreviewed'),
  ('us.marca.com','Marca USA','ESTABLISHED_MEDIA','US','Official Liga MX RSS index verified; publisher location is not story country'),
  ('bbc.co.uk','BBC Sport','ESTABLISHED_MEDIA','GB','Official football RSS guidance verified; HTTPS endpoint not confirmed'),
  ('mediotiempo.com','Mediotiempo','ESTABLISHED_MEDIA','MX','Historical HTTP RSS documented; current HTTPS endpoint not confirmed'),
  ('ole.com.ar','Olé','ESTABLISHED_MEDIA','AR','Football coverage verified; official feed not confirmed'),
  ('tycsports.com','TyC Sports','ESTABLISHED_MEDIA','AR','Football coverage verified; official feed not confirmed'),
  ('uefa.com','UEFA','FIRST_PARTY_OFFICIAL',null,'Official news; feed and commercial rights not confirmed'),
  ('conmebol.com','CONMEBOL','FIRST_PARTY_OFFICIAL',null,'Official news; feed and commercial rights not confirmed')
on conflict(domain) do nothing;

insert into futbeat_private.news_feeds
  (id,url,source_domain,cadence_minutes,coverage_country_code,language_code) values
  ('as-futbol','https://feeds.as.com/mrss-s/pages/as/site/as.com/section/futbol/portada/','as.com',60,'ES','es'),
  ('clarin-futbol','https://www.clarin.com/rss/deportes/futbol/','clarin.com',60,'AR','es'),
  ('ge-futebol','https://ge.globo.com/Esportes/Rss/0,,AS0-9825,00.xml','ge.globo.com',60,'BR','pt'),
  ('eltiempo-futbol-co','https://www.eltiempo.com/rss/deportes_futbol-colombiano.xml','eltiempo.com',60,'CO','es'),
  ('marca-liga-mx','https://e00-us-marca.uecdn.es/rss/soccer/liga-mx.xml','us.marca.com',60,'MX','es')
on conflict(id) do nothing;

update futbeat_private.news_feeds set coverage_country_code='CR',language_code='es'
where id='teletica-futbol' and coverage_country_code is null;
