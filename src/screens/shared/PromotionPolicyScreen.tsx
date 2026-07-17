/**
 * PromotionPolicyScreen — Políticas de promoción y publicidad.
 *
 * UNA sola política que cubre TODOS los productos de Promocionarse:
 * Bidding, Recomendado, Destacado, Banner Home y Anuncio en Perfil.
 * Accesible desde el pie de Promocionarse. Marco de intermediario
 * (protección legal de la plataforma) incluido.
 */
import React from 'react';
import { ScrollView, StyleSheet, Text, View, Pressable } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ArrowLeft } from 'lucide-react-native';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

function Card({ icon, title, children }: { icon: string; title: string; children: React.ReactNode }) {
  return (
    <View style={s.card}>
      <View style={s.cardHead}>
        <Text style={s.cardIcon}>{icon}</Text>
        <Text style={s.cardTitle}>{title}</Text>
      </View>
      {children}
    </View>
  );
}

export default function PromotionPolicyScreen({ route, navigation }: any) {
  // Cada rol ve SOLO sus productos: el cliente no lee sobre Bidding,
  // Destacado, ranking ni sanciones de grupos — eso es del grupo.
  const role: 'client' | 'group' = route?.params?.role === 'group' ? 'group' : 'client';
  const isGroup = role === 'group';

  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={{ flex: 1 }}>
        <View style={s.header}>
          <Pressable style={s.backBtn} onPress={() => navigation.goBack()} hitSlop={8}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <View style={{ flex: 1 }}>
            <Text style={s.headerTitle}>Políticas de publicidad</Text>
            <Text style={s.headerSub}>{isGroup ? 'Para grupos' : 'Para anunciantes'}</Text>
          </View>
        </View>

        <ScrollView contentContainerStyle={s.scroll} showsVerticalScrollIndicator={false}>

          <View style={s.introCard}>
            <Text style={s.introTitle}>📢 Una sola política, todos los productos</Text>
            <Text style={s.introText}>
              {isGroup ? (
                <>Lo aquí descrito aplica por igual a <Text style={s.bold}>Bidding, Recomendado,
                Destacado, Banner Home y Anuncio en Perfil</Text>, y a cualquier producto de
                promoción que se agregue en el futuro.</>
              ) : (
                <>Lo aquí descrito aplica por igual a <Text style={s.bold}>Banner Home y Anuncio
                en Perfil</Text>, y a cualquier producto de publicidad que se agregue en el
                futuro.</>
              )}
            </Text>
          </View>

          <Card icon="👁️" title="Qué compras: visibilidad, no resultados">
            <Text style={s.body}>
              {isGroup ? (
                <>Los productos de promoción aumentan tu <Text style={s.bold}>exposición</Text> dentro
                de la app durante el periodo contratado. No garantizan cotizaciones, contrataciones
                ni resultados de negocio — eso depende de tu perfil, precios, reseñas y trato con
                los clientes.</>
              ) : (
                <>Tu anuncio se muestra dentro de la app durante el periodo contratado. La
                publicidad compra <Text style={s.bold}>exposición</Text>, no garantiza clics,
                ventas ni resultados de negocio.</>
              )}
            </Text>
          </Card>

          <Card icon="🔍" title="Revisión y aprobación">
            <Text style={s.body}>
              Todo anuncio con contenido (imagen, video o texto) se{' '}
              <Text style={s.bold}>revisa antes de publicarse</Text>. Nos reservamos el derecho de
              rechazar contenido que: incluya datos de contacto (teléfonos, redes, correos),
              material del que no seas titular, información engañosa sobre precios o servicios, o
              cualquier contenido ofensivo o ilegal. Si tu anuncio es rechazado,{' '}
              <Text style={s.bold}>no se publica y no se te cobra</Text> (o se te reembolsa si el
              cargo ya se había procesado).
            </Text>
          </Card>

          <Card icon="⏳" title="Vigencia y pagos">
            <Text style={s.body}>
              Cada producto tiene una <Text style={s.bold}>duración definida</Text> que eliges al
              contratarlo y termina automáticamente. Una vez que la campaña{' '}
              <Text style={s.bold}>inicia</Text>, el pago no es reembolsable: el espacio
              publicitario ya fue reservado y servido. Pagas con tarjeta, OXXO o SPEI y
              queda registro de cada campaña.
            </Text>
          </Card>

          <Card icon="🔁" title="Renovación automática (solo si tú la eliges)">
            <Text style={s.body}>
              Los pagos normales son de <Text style={s.bold}>una sola vez</Text> — nadie te
              vuelve a cobrar. Solo las opciones marcadas como{' '}
              <Text style={s.bold}>"se renueva solo"</Text> (suscripción semanal de Recomendado,
              mensual de Destacado, o la insignia Plus) cobran tu tarjeta automáticamente cada
              periodo hasta que canceles. Puedes cancelar cuando quieras y lo ya pagado sigue
              activo hasta su fecha de vencimiento.
            </Text>
          </Card>

          <Card icon="📍" title="Espacios limitados por estado">
            <Text style={s.body}>
              Para que la publicidad se vea y rote bien, cada estado tiene un número{' '}
              <Text style={s.bold}>limitado de espacios</Text> por tipo de anuncio (los
              nacionales e internacionales tienen su propia bolsa). Si un estado está lleno,
              la app te avisa antes de cobrar; los lugares se liberan cuando vencen las
              campañas activas.
            </Text>
          </Card>

          {isGroup && (
            <Card icon="⚖️" title="Juego limpio en el ranking">
              <Text style={s.body}>
                En <Text style={s.bold}>Bidding</Text> gana la puja más alta activa y las posiciones
                pueden cambiar en cualquier momento si otro grupo puja más — es la naturaleza del
                producto. Está prohibido manipular reseñas, crear perfiles falsos o cualquier
                práctica para inflar artificialmente la posición: se sanciona con la cancelación de
                las promociones activas sin reembolso y posible suspensión.
              </Text>
            </Card>
          )}

          {isGroup && (
            <Card icon="🚨" title="Sanciones pesan más que promociones">
              <Text style={s.body}>
                Las sanciones por incumplimiento (cancelar eventos pagados, no presentarse,
                strikes) <Text style={s.bold}>prevalecen sobre cualquier promoción activa</Text>: un
                grupo con castigo de visibilidad baja al fondo del explorador aunque tenga una puja
                o promoción vigente, sin derecho a reembolso por el periodo del castigo. Un grupo
                suspendido pierde sus promociones activas.
              </Text>
            </Card>
          )}

          {!isGroup && (
            <Card icon="©️" title="Derechos del contenido">
              <Text style={s.body}>
                Al pagar un anuncio declaras que las imágenes, videos y música que subes son
                tuyos o cuentas con autorización para usarlos. Si un titular de derechos reclama,
                el anuncio puede retirarse y la responsabilidad es de quien lo subió (ver
                Términos y condiciones, sección de contenido).
              </Text>
            </Card>
          )}

          <View style={s.legalCard}>
            <Text style={s.legalText}>
              Daricefy actúa como plataforma tecnológica que presta espacios de visibilidad
              dentro de su propia app. La contratación de promoción no crea sociedad, agencia ni
              garantía de resultados. Al contratar cualquier producto de promoción aceptas estas
              políticas, que pueden actualizarse — la versión vigente estará siempre en esta
              pantalla.
            </Text>
            <Text style={s.legalDate}>Última actualización: julio 2026 · Daricefy</Text>
          </View>

        </ScrollView>
      </SafeAreaView>
    </View>
  );
}

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: COLORS.bg },
  header: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    paddingHorizontal: SPACING.xl, paddingVertical: 12,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12, alignItems: 'center', justifyContent: 'center',
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  headerTitle: { fontFamily: FONTS.title, fontSize: 17, color: COLORS.text },
  headerSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 1 },
  scroll: { padding: SPACING.xl, paddingBottom: 40, gap: 12 },

  introCard: {
    backgroundColor: 'rgba(0,230,118,0.06)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.30)', padding: 16,
  },
  introTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14.5, color: COLORS.green, marginBottom: 6 },
  introText:  { fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.text, lineHeight: 19 },

  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 16,
  },
  cardHead:  { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 10 },
  cardIcon:  { fontSize: 16 },
  cardTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14.5, color: COLORS.text, flex: 1 },
  body: { fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.text, lineHeight: 19 },
  bold: { fontFamily: FONTS.bodySemiBold, color: COLORS.text },

  legalCard: {
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border, padding: 16, marginTop: 4,
  },
  legalText: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, lineHeight: 17 },
  legalDate: { fontFamily: FONTS.bodyMedium, fontSize: 10.5, color: COLORS.muted, marginTop: 10 },
});
