-- ============================================================
-- sql/264_set_state_from_city.sql
--
-- Asigna el campo `state` a grupos y perfiles existentes
-- que solo tienen `city` registrada (registrados antes de que
-- se agregara el campo state en SQL 175).
--
-- Cubre las ciudades más importantes de México.
-- Seguro: solo actualiza registros donde state IS NULL o vacío.
-- ============================================================

-- ── Función auxiliar de limpieza ─────────────────────────────────────────────
-- Normaliza el nombre de ciudad para comparación
-- (minúsculas + trim + quita acentos básicos)

CREATE OR REPLACE FUNCTION _tmp_norm_city(c TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT LOWER(TRIM(
    REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
      REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(c,
      'á','a'),'é','e'),'í','i'),'ó','o'),'ú','u'),
      'Á','a'),'É','e'),'Í','i'),'Ó','o'),'Ú','u'),
      'ü','u'),'ñ','n')
  ));
$$;

-- ── Actualizar grupos ────────────────────────────────────────────────────────

UPDATE public.groups SET state = mapped.state
FROM (VALUES
  -- CDMX
  ('ciudad de mexico','CDMX'), ('cdmx','CDMX'), ('df','CDMX'),
  ('ciudad de mexico df','CDMX'), ('mexico city','CDMX'),
  ('benito juarez','CDMX'), ('coyoacan','CDMX'), ('iztapalapa','CDMX'),
  ('xochimilco','CDMX'), ('tlalpan','CDMX'), ('cuauhtemoc','CDMX'),
  ('miguel hidalgo','CDMX'), ('azcapotzalco','CDMX'), ('tlahuac','CDMX'),
  ('alvaro obregon','CDMX'), ('gustavo a madero','CDMX'), ('milpa alta','CDMX'),
  ('la magdalena contreras','CDMX'), ('venustiano carranza','CDMX'),
  ('iztacalco','CDMX'),
  -- Jalisco
  ('guadalajara','Jalisco'), ('zapopan','Jalisco'), ('tlaquepaque','Jalisco'),
  ('san pedro tlaquepaque','Jalisco'), ('tonala','Jalisco'), ('tonala jalisco','Jalisco'),
  ('tlajomulco','Jalisco'), ('tlajomulco de zuniga','Jalisco'),
  ('el salto','Jalisco'), ('lagos de moreno','Jalisco'),
  ('puerto vallarta','Jalisco'), ('tepatitlan','Jalisco'),
  ('ocotlan','Jalisco'), ('tepatitlan de morelos','Jalisco'),
  ('ameca','Jalisco'), ('autlan de navarro','Jalisco'),
  ('ciudad guzman','Jalisco'), ('zapotlanejo','Jalisco'),
  -- Nuevo León
  ('monterrey','Nuevo León'), ('san nicolas','Nuevo León'),
  ('san nicolas de los garza','Nuevo León'), ('guadalupe','Nuevo León'),
  ('san pedro garza garcia','Nuevo León'), ('apodaca','Nuevo León'),
  ('escobedo','Nuevo León'), ('general escobedo','Nuevo León'),
  ('santa catarina','Nuevo León'), ('juarez','Nuevo León'),
  ('garcia','Nuevo León'), ('cadereyta','Nuevo León'),
  ('linares','Nuevo León'), ('montemorelos','Nuevo León'),
  -- Estado de México
  ('ecatepec','Estado de México'), ('naucalpan','Estado de México'),
  ('toluca','Estado de México'), ('nezahualcoyotl','Estado de México'),
  ('neza','Estado de México'), ('chimalhuacan','Estado de México'),
  ('tlalnepantla','Estado de México'), ('cuautitlan','Estado de México'),
  ('cuautitlan izcalli','Estado de México'), ('tultitlan','Estado de México'),
  ('atizapan','Estado de México'), ('atizapan de zaragoza','Estado de México'),
  ('coacalco','Estado de México'), ('texcoco','Estado de México'),
  ('metepec','Estado de México'), ('ixtapaluca','Estado de México'),
  -- Puebla
  ('puebla','Puebla'), ('tehuacan','Puebla'), ('atlixco','Puebla'),
  ('cholula','Puebla'), ('san andres cholula','Puebla'),
  ('san martin texmelucan','Puebla'), ('teziutlan','Puebla'),
  -- Veracruz
  ('veracruz','Veracruz'), ('xalapa','Veracruz'), ('jalapa','Veracruz'),
  ('coatzacoalcos','Veracruz'), ('orizaba','Veracruz'),
  ('poza rica','Veracruz'), ('minatitlan','Veracruz'),
  ('boca del rio','Veracruz'), ('cordoba','Veracruz'),
  -- Guanajuato
  ('leon','Guanajuato'), ('leon de los aldama','Guanajuato'),
  ('irapuato','Guanajuato'), ('celaya','Guanajuato'),
  ('guanajuato','Guanajuato'), ('salamanca','Guanajuato'),
  ('silao','Guanajuato'), ('san miguel de allende','Guanajuato'),
  -- Baja California
  ('tijuana','Baja California'), ('mexicali','Baja California'),
  ('ensenada','Baja California'), ('tecate','Baja California'),
  ('rosarito','Baja California'), ('playas de rosarito','Baja California'),
  -- Baja California Sur
  ('la paz','Baja California Sur'), ('los cabos','Baja California Sur'),
  ('cabo san lucas','Baja California Sur'), ('san jose del cabo','Baja California Sur'),
  ('loreto','Baja California Sur'),
  -- Sonora
  ('hermosillo','Sonora'), ('ciudad obregon','Sonora'), ('obregon','Sonora'),
  ('nogales','Sonora'), ('san luis rio colorado','Sonora'),
  ('navojoa','Sonora'), ('guaymas','Sonora'),
  -- Chihuahua
  ('ciudad juarez','Chihuahua'), ('juarez chihuahua','Chihuahua'),
  ('chihuahua','Chihuahua'), ('delicias','Chihuahua'),
  ('cuauhtemoc chihuahua','Chihuahua'), ('parral','Chihuahua'),
  ('hidalgo del parral','Chihuahua'),
  -- Tamaulipas
  ('reynosa','Tamaulipas'), ('nuevo laredo','Tamaulipas'),
  ('matamoros','Tamaulipas'), ('victoria','Tamaulipas'),
  ('ciudad victoria','Tamaulipas'), ('tampico','Tamaulipas'),
  -- Coahuila
  ('saltillo','Coahuila'), ('torreon','Coahuila'),
  ('monclova','Coahuila'), ('piedras negras','Coahuila'),
  ('acuna','Coahuila'), ('ciudad acuna','Coahuila'),
  -- Sinaloa
  ('culiacan','Sinaloa'), ('mazatlan','Sinaloa'),
  ('los mochis','Sinaloa'), ('guasave','Sinaloa'),
  ('ahome','Sinaloa'),
  -- Oaxaca
  ('oaxaca','Oaxaca'), ('oaxaca de juarez','Oaxaca'),
  ('juchitan','Oaxaca'), ('salina cruz','Oaxaca'), ('tuxtepec','Oaxaca'),
  -- Tabasco
  ('villahermosa','Tabasco'), ('cardenas','Tabasco'), ('comalcalco','Tabasco'),
  -- Guerrero
  ('acapulco','Guerrero'), ('chilpancingo','Guerrero'),
  ('zihuatanejo','Guerrero'), ('iguala','Guerrero'),
  -- Michoacán
  ('morelia','Michoacán'), ('uruapan','Michoacán'),
  ('zamora','Michoacán'), ('lazaro cardenas','Michoacán'),
  -- Hidalgo
  ('pachuca','Hidalgo'), ('pachuca de soto','Hidalgo'),
  ('tulancingo','Hidalgo'), ('tula','Hidalgo'),
  -- Querétaro
  ('queretaro','Querétaro'), ('queretaro de arteaga','Querétaro'),
  ('san juan del rio','Querétaro'), ('corregidora','Querétaro'),
  -- Quintana Roo
  ('cancun','Quintana Roo'), ('playa del carmen','Quintana Roo'),
  ('chetumal','Quintana Roo'), ('cozumel','Quintana Roo'),
  ('tulum','Quintana Roo'),
  -- Yucatán
  ('merida','Yucatán'), ('valladolid','Yucatán'), ('progreso','Yucatán'),
  -- Chiapas
  ('tuxtla gutierrez','Chiapas'), ('tuxtla','Chiapas'),
  ('san cristobal de las casas','Chiapas'), ('tapachula','Chiapas'),
  ('comitan','Chiapas'),
  -- Nayarit
  ('tepic','Nayarit'), ('bahia de banderas','Nayarit'), ('bucerias','Nayarit'),
  -- Aguascalientes
  ('aguascalientes','Aguascalientes'), ('jesus maria','Aguascalientes'),
  -- Colima
  ('colima','Colima'), ('manzanillo','Colima'), ('tecoman','Colima'),
  -- Durango
  ('durango','Durango'), ('gomez palacio','Durango'), ('lerdo','Durango'),
  -- Morelos
  ('cuernavaca','Morelos'), ('cuautla','Morelos'), ('jiutepec','Morelos'),
  ('temixco','Morelos'),
  -- Tlaxcala
  ('tlaxcala','Tlaxcala'), ('apizaco','Tlaxcala'), ('huamantla','Tlaxcala'),
  -- Zacatecas
  ('zacatecas','Zacatecas'), ('fresnillo','Zacatecas'), ('guadalupe zacatecas','Zacatecas'),
  -- San Luis Potosí
  ('san luis potosi','San Luis Potosí'), ('ciudad valles','San Luis Potosí'),
  ('matehuala','San Luis Potosí'), ('rioverde','San Luis Potosí'),
  -- Campeche
  ('campeche','Campeche'), ('ciudad del carmen','Campeche'),
  -- Nuevo León (extra)
  ('sabinas hidalgo','Nuevo León')
) AS mapped(city_norm, state)
WHERE (public.groups.state IS NULL OR TRIM(public.groups.state) = '')
  AND _tmp_norm_city(public.groups.city) = mapped.city_norm;

-- ── Actualizar profiles (talentos y grupos) ──────────────────────────────────

UPDATE public.profiles SET state = mapped.state
FROM (VALUES
  -- CDMX
  ('ciudad de mexico','CDMX'), ('cdmx','CDMX'), ('df','CDMX'),
  ('mexico city','CDMX'), ('benito juarez','CDMX'), ('coyoacan','CDMX'),
  ('iztapalapa','CDMX'), ('xochimilco','CDMX'), ('tlalpan','CDMX'),
  ('cuauhtemoc','CDMX'), ('miguel hidalgo','CDMX'), ('azcapotzalco','CDMX'),
  ('alvaro obregon','CDMX'), ('gustavo a madero','CDMX'), ('iztacalco','CDMX'),
  ('venustiano carranza','CDMX'), ('tlahuac','CDMX'), ('milpa alta','CDMX'),
  ('la magdalena contreras','CDMX'),
  -- Jalisco
  ('guadalajara','Jalisco'), ('zapopan','Jalisco'), ('tlaquepaque','Jalisco'),
  ('san pedro tlaquepaque','Jalisco'), ('tonala','Jalisco'),
  ('tlajomulco','Jalisco'), ('tlajomulco de zuniga','Jalisco'),
  ('el salto','Jalisco'), ('lagos de moreno','Jalisco'),
  ('puerto vallarta','Jalisco'), ('tepatitlan','Jalisco'),
  ('ocotlan','Jalisco'), ('ciudad guzman','Jalisco'), ('zapotlanejo','Jalisco'),
  ('ameca','Jalisco'), ('autlan de navarro','Jalisco'),
  -- Nuevo León
  ('monterrey','Nuevo León'), ('san nicolas','Nuevo León'),
  ('san nicolas de los garza','Nuevo León'), ('guadalupe','Nuevo León'),
  ('san pedro garza garcia','Nuevo León'), ('apodaca','Nuevo León'),
  ('escobedo','Nuevo León'), ('general escobedo','Nuevo León'),
  ('santa catarina','Nuevo León'), ('garcia','Nuevo León'),
  ('juarez','Nuevo León'), ('cadereyta','Nuevo León'), ('linares','Nuevo León'),
  -- Estado de México
  ('ecatepec','Estado de México'), ('naucalpan','Estado de México'),
  ('toluca','Estado de México'), ('nezahualcoyotl','Estado de México'),
  ('neza','Estado de México'), ('chimalhuacan','Estado de México'),
  ('tlalnepantla','Estado de México'), ('cuautitlan','Estado de México'),
  ('cuautitlan izcalli','Estado de México'), ('tultitlan','Estado de México'),
  ('atizapan','Estado de México'), ('atizapan de zaragoza','Estado de México'),
  ('coacalco','Estado de México'), ('texcoco','Estado de México'),
  ('metepec','Estado de México'), ('ixtapaluca','Estado de México'),
  -- Puebla
  ('puebla','Puebla'), ('tehuacan','Puebla'), ('atlixco','Puebla'),
  ('cholula','Puebla'), ('san andres cholula','Puebla'), ('teziutlan','Puebla'),
  -- Veracruz
  ('veracruz','Veracruz'), ('xalapa','Veracruz'), ('jalapa','Veracruz'),
  ('coatzacoalcos','Veracruz'), ('orizaba','Veracruz'), ('poza rica','Veracruz'),
  ('boca del rio','Veracruz'), ('cordoba','Veracruz'),
  -- Guanajuato
  ('leon','Guanajuato'), ('leon de los aldama','Guanajuato'),
  ('irapuato','Guanajuato'), ('celaya','Guanajuato'), ('guanajuato','Guanajuato'),
  ('salamanca','Guanajuato'), ('silao','Guanajuato'),
  ('san miguel de allende','Guanajuato'),
  -- Baja California
  ('tijuana','Baja California'), ('mexicali','Baja California'),
  ('ensenada','Baja California'), ('tecate','Baja California'),
  ('rosarito','Baja California'), ('playas de rosarito','Baja California'),
  -- Baja California Sur
  ('la paz','Baja California Sur'), ('los cabos','Baja California Sur'),
  ('cabo san lucas','Baja California Sur'), ('san jose del cabo','Baja California Sur'),
  ('loreto','Baja California Sur'),
  -- Sonora
  ('hermosillo','Sonora'), ('ciudad obregon','Sonora'), ('nogales','Sonora'),
  ('san luis rio colorado','Sonora'), ('navojoa','Sonora'), ('guaymas','Sonora'),
  -- Chihuahua
  ('ciudad juarez','Chihuahua'), ('chihuahua','Chihuahua'),
  ('delicias','Chihuahua'), ('parral','Chihuahua'),
  -- Tamaulipas
  ('reynosa','Tamaulipas'), ('nuevo laredo','Tamaulipas'),
  ('matamoros','Tamaulipas'), ('ciudad victoria','Tamaulipas'),
  ('victoria','Tamaulipas'), ('tampico','Tamaulipas'),
  -- Coahuila
  ('saltillo','Coahuila'), ('torreon','Coahuila'),
  ('monclova','Coahuila'), ('piedras negras','Coahuila'),
  -- Sinaloa
  ('culiacan','Sinaloa'), ('mazatlan','Sinaloa'), ('los mochis','Sinaloa'),
  -- Oaxaca
  ('oaxaca','Oaxaca'), ('oaxaca de juarez','Oaxaca'), ('juchitan','Oaxaca'),
  ('salina cruz','Oaxaca'), ('tuxtepec','Oaxaca'),
  -- Tabasco
  ('villahermosa','Tabasco'), ('cardenas','Tabasco'),
  -- Guerrero
  ('acapulco','Guerrero'), ('chilpancingo','Guerrero'),
  ('zihuatanejo','Guerrero'), ('iguala','Guerrero'),
  -- Michoacán
  ('morelia','Michoacán'), ('uruapan','Michoacán'),
  ('zamora','Michoacán'), ('lazaro cardenas','Michoacán'),
  -- Hidalgo
  ('pachuca','Hidalgo'), ('tulancingo','Hidalgo'), ('tula','Hidalgo'),
  -- Querétaro
  ('queretaro','Querétaro'), ('san juan del rio','Querétaro'),
  -- Quintana Roo
  ('cancun','Quintana Roo'), ('playa del carmen','Quintana Roo'),
  ('chetumal','Quintana Roo'), ('cozumel','Quintana Roo'), ('tulum','Quintana Roo'),
  -- Yucatán
  ('merida','Yucatán'), ('valladolid','Yucatán'), ('progreso','Yucatán'),
  -- Chiapas
  ('tuxtla gutierrez','Chiapas'), ('san cristobal de las casas','Chiapas'),
  ('tapachula','Chiapas'),
  -- Nayarit
  ('tepic','Nayarit'), ('bahia de banderas','Nayarit'),
  -- Aguascalientes
  ('aguascalientes','Aguascalientes'),
  -- Colima
  ('colima','Colima'), ('manzanillo','Colima'),
  -- Durango
  ('durango','Durango'), ('gomez palacio','Durango'),
  -- Morelos
  ('cuernavaca','Morelos'), ('cuautla','Morelos'),
  -- Tlaxcala
  ('tlaxcala','Tlaxcala'), ('apizaco','Tlaxcala'),
  -- Zacatecas
  ('zacatecas','Zacatecas'), ('fresnillo','Zacatecas'),
  -- San Luis Potosí
  ('san luis potosi','San Luis Potosí'), ('ciudad valles','San Luis Potosí'),
  -- Campeche
  ('campeche','Campeche'), ('ciudad del carmen','Campeche'),
  -- Quintana Roo extra
  ('benito juarez','Quintana Roo')  -- Benito Juárez municipio = Cancún
) AS mapped(city_norm, state)
WHERE (public.profiles.state IS NULL OR TRIM(public.profiles.state) = '')
  AND public.profiles.city IS NOT NULL
  AND _tmp_norm_city(public.profiles.city) = mapped.city_norm;

-- ── Limpiar función temporal ─────────────────────────────────────────────────
DROP FUNCTION IF EXISTS _tmp_norm_city(TEXT);

-- ── Verificar resultado ──────────────────────────────────────────────────────
SELECT
  'grupos_actualizados' AS tipo,
  state,
  COUNT(*) AS total
FROM public.groups
WHERE state IS NOT NULL
GROUP BY state
ORDER BY total DESC
LIMIT 20;
