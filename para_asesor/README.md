# Daricefy — Paquete para Asesor de Diseño/UI

## Contenido de esta carpeta

### Documentación (leer primero)
| Archivo | Contenido |
|---|---|
| `01_FLUJOS_PASO_A_PASO.md` | Cómo fluyen Express y Programadas, pantalla por pantalla |
| `02_PANTALLAS_VISUAL.md` | Descripción visual de cada pantalla + sugerencias de diseño |
| `03_BASE_DE_DATOS.md` | Tablas, columnas, relaciones y ciclo de vida de status |

### Código (carpeta `code/`)
| Archivo | Pantalla |
|---|---|
| `GuidedRequestScreen.tsx` | Cliente — Solicitud Express en 3 pasos |
| `OpenRequestScreen.tsx` | Cliente — Ver mis solicitudes + aceptar propuesta |
| `QuoteFormScreen.tsx` | Cliente — Solicitar cotización a grupo específico |
| `ClientQuoteDetailScreen.tsx` | Cliente — Ver cotización del grupo y pagar |
| `MapAddressPicker.tsx` | Componente — Selector de dirección en mapa interactivo |
| `create_payment_intent.ts` | Edge Function — Crea PaymentIntent en Stripe (50% anticipo) |
| `stripe_webhook.ts` | Edge Function — Confirma pagos y cobra el restante |

## Paleta de colores (NO cambiar)
```
bg:      #040404   fondo global
card:    #0e0e0e   tarjetas
card2:   #151515   elementos internos
green:   #00E676   acción principal, confirmado
orange:  #FFB300   pendiente, advertencia
blue:    #40C4FF   en proceso
red:     #FF5252   cancelado, error
text:    #FFFFFF
muted:   #555555
muted2:  #8A8A8A
border:  #1C1C1C
```

## Tipografía
```
Títulos:  Syne_800ExtraBold
Cuerpo:   DMSans_400 / DMSans_500Medium / DMSans_600SemiBold
```

## Stack
- React Native + Expo SDK 54 (TypeScript)
- Supabase (PostgreSQL + Auth + Realtime)
- Stripe (@stripe/stripe-react-native)
- react-native-maps (MapView + Marker + Circle)
- expo-location (GPS + reverse geocode)
