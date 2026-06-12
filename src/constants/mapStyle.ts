// ============================================================
// Estilo de mapa unificado de Daricefy (Google Maps).
//
// "Earth" dark — océano azul profundo, continentes con matiz
// natural, fronteras de país visibles. Alejado se ve como un
// planeta; de cerca las calles siguen legibles.
//
// Única fuente de verdad para TODAS las superficies de mapa:
// AdminMapScreen, OpenRequestsScreen, IncomingExpressScreen,
// ExpressCard, GroupsMapScreen, MapAddressPicker, EventTimer.
// Requiere provider={PROVIDER_GOOGLE} (en iOS el provider Apple
// ignora customMapStyle).
// ============================================================

export const EARTH_STYLE = [
  { elementType: 'geometry',                              stylers: [{ color: '#121a28' }] },
  { elementType: 'labels.text.fill',                     stylers: [{ color: '#8fa3c0' }] },
  { elementType: 'labels.text.stroke',                   stylers: [{ color: '#0a1220' }] },
  { elementType: 'labels.icon',                          stylers: [{ visibility: 'off' }] },
  { featureType: 'water',        elementType: 'geometry', stylers: [{ color: '#06162c' }] },
  { featureType: 'water',        elementType: 'labels.text.fill', stylers: [{ color: '#3a608f' }] },
  { featureType: 'landscape',    elementType: 'geometry', stylers: [{ color: '#16202c' }] },
  { featureType: 'landscape.natural', elementType: 'geometry', stylers: [{ color: '#172a20' }] },
  { featureType: 'poi.park',     elementType: 'geometry', stylers: [{ color: '#163022' }] },
  { featureType: 'poi',          elementType: 'labels.text.fill', stylers: [{ color: '#567a5e' }] },
  { featureType: 'road',         elementType: 'geometry.fill',   stylers: [{ color: '#22304a' }] },
  { featureType: 'road',         elementType: 'geometry.stroke', stylers: [{ color: '#141f36' }] },
  { featureType: 'road',         elementType: 'labels.text.fill', stylers: [{ color: '#7187a8' }] },
  { featureType: 'road.highway', elementType: 'geometry.fill',   stylers: [{ color: '#2b4a76' }] },
  { featureType: 'road.highway', elementType: 'geometry.stroke', stylers: [{ color: '#15294d' }] },
  { featureType: 'road.arterial',elementType: 'geometry',        stylers: [{ color: '#1e2b42' }] },
  { featureType: 'transit',      elementType: 'geometry',        stylers: [{ color: '#1a2940' }] },
  { featureType: 'transit.station', elementType: 'labels.text.fill', stylers: [{ color: '#4f6f9e' }] },
  { featureType: 'administrative', elementType: 'geometry.stroke', stylers: [{ color: '#3f5d85' }] },
  { featureType: 'administrative.country',  elementType: 'geometry.stroke', stylers: [{ color: '#52719f' }, { weight: 1.1 }] },
  { featureType: 'administrative.province', elementType: 'geometry.stroke', stylers: [{ color: '#2b4263' }] },
  { featureType: 'administrative.locality', elementType: 'labels.text.fill', stylers: [{ color: '#cdd9ea' }] },
  { featureType: 'administrative.country',  elementType: 'labels.text.fill', stylers: [{ color: '#9db1d0' }] },
];
