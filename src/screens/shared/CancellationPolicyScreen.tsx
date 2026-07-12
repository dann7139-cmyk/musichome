/**
 * CancellationPolicyScreen — Políticas de cancelación (cliente y grupo).
 *
 * Accesible desde el pie de la lista de eventos ("Políticas de cancelación",
 * junto a Soporte). Contenido por rol:
 *   - client: qué recupera si cancela, qué pasa si cancela el grupo, cómo
 *     llegan los reembolsos. NUNCA se menciona lo que gana la plataforma.
 *   - group: castigos por cancelar, compensaciones si cancela el cliente,
 *     no-show, talento invitado.
 * Ambos ven el marco de INTERMEDIARIO: Daricefy conecta y custodia el pago,
 * no es parte del contrato entre cliente y grupo.
 */
import React from 'react';
import { ScrollView, StyleSheet, Text, View, Pressable } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ArrowLeft } from 'lucide-react-native';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

type Row = { when: string; result: string; highlight?: boolean };

function PolicyCard({ icon, title, children }: { icon: string; title: string; children: React.ReactNode }) {
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

function PolicyRows({ rows }: { rows: Row[] }) {
  return (
    <View style={s.rows}>
      {rows.map((r, i) => (
        <View key={i} style={[s.row, i < rows.length - 1 && s.rowDivider]}>
          <Text style={s.rowWhen}>{r.when}</Text>
          <Text style={[s.rowResult, r.highlight && s.rowResultGreen]}>{r.result}</Text>
        </View>
      ))}
    </View>
  );
}

export default function CancellationPolicyScreen({ route, navigation }: any) {
  const role: 'client' | 'group' = route?.params?.role === 'group' ? 'group' : 'client';

  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={{ flex: 1 }}>
        <View style={s.header}>
          <Pressable style={s.backBtn} onPress={() => navigation.goBack()} hitSlop={8}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <View style={{ flex: 1 }}>
            <Text style={s.headerTitle}>Políticas de cancelación</Text>
            <Text style={s.headerSub}>{role === 'group' ? 'Para grupos' : 'Para clientes'}</Text>
          </View>
        </View>

        <ScrollView contentContainerStyle={s.scroll} showsVerticalScrollIndicator={false}>

          {/* ── Marco de intermediario (ambos roles) ── */}
          <View style={s.introCard}>
            <Text style={s.introTitle}>🤝 Daricefy es el intermediario</Text>
            <Text style={s.introText}>
              Somos una plataforma tecnológica que conecta clientes con grupos musicales
              independientes y <Text style={s.bold}>custodia el pago para proteger a las dos partes</Text>.
              Los grupos no son empleados ni representantes de Daricefy: cada grupo es
              responsable de su servicio y cada cliente de la información de su evento.
              El dinero queda protegido en custodia y solo se entrega al grupo cuando el
              evento se cumple.
            </Text>
          </View>

          {role === 'client' ? (
            <>
              <PolicyCard icon="🗓️" title="Si tú cancelas">
                <PolicyRows rows={[
                  { when: 'Más de 15 días antes',  result: 'Recuperas el 100%', highlight: true },
                  { when: 'Entre 7 y 15 días',     result: 'Recuperas el 90%' },
                  { when: 'Menos de 7 días',       result: 'Recuperas el 75%' },
                  { when: 'Evento express (hoy)',  result: 'Recuperas el 75%' },
                ]} />
                <Text style={s.note}>
                  ¿Por qué hay un cargo? Cuando el grupo acepta tu evento aparta esa fecha
                  y deja pasar otras oportunidades de tocar. El cargo lo compensa por la
                  fecha que reservó para ti.
                </Text>
              </PolicyCard>

              <PolicyCard icon="🛡️" title="Si el grupo cancela o no llega">
                <Text style={s.body}>
                  Recuperas el <Text style={s.bold}>100% de tu pago, siempre</Text>. Además el
                  grupo recibe sanciones automáticas: strike en su historial, pérdida de su
                  insignia de verificado y menos visibilidad en la plataforma. La llegada del
                  grupo se verifica por GPS — si no se presenta, tu pago queda bloqueado y se
                  te reembolsa completo tras la revisión.
                </Text>
              </PolicyCard>

              <PolicyCard icon="💸" title="Cómo llega tu reembolso">
                <PolicyRows rows={[
                  { when: 'Pagaste con tarjeta',        result: 'Automático · 3-10 días hábiles' },
                  { when: 'Pagaste por SPEI o efectivo', result: 'Transferencia · máx. 5 días hábiles' },
                ]} />
                <Text style={s.note}>
                  Para SPEI/efectivo te pedimos tu CLABE al cancelar y te avisamos cuando la
                  transferencia esté enviada — con comprobante visible en tu evento.
                </Text>
              </PolicyCard>

              <PolicyCard icon="🔒" title="Tu pago siempre protegido">
                <Text style={s.body}>
                  Tu dinero nunca se le entrega al grupo por adelantado: queda en custodia de
                  Daricefy y se libera únicamente cuando el evento termina. Si algo sale mal,
                  puedes abrir una disputa desde la app y nuestro equipo la resuelve.
                </Text>
              </PolicyCard>
            </>
          ) : (
            <>
              <PolicyCard icon="🚨" title="Si tú cancelas un evento pagado">
                <PolicyRows rows={[
                  { when: 'Reembolso al cliente', result: '100% de su pago' },
                  { when: 'Strike',               result: '1 por cancelación · al 3º tu grupo se SUSPENDE' },
                  { when: 'Verificación',         result: 'Pierdes tu insignia de verificado' },
                  { when: 'Visibilidad',          result: 'Al fondo del explorador por 30 días' },
                ]} />
                <Text style={s.note}>
                  Cancelar afecta al cliente que confió en ustedes. Si de verdad no pueden
                  asistir, cancela lo antes posible desde el detalle del evento — y si es una
                  emergencia, contacta a soporte antes de cancelar.
                </Text>
              </PolicyCard>

              <PolicyCard icon="💰" title="Si el cliente cancela">
                <PolicyRows rows={[
                  { when: 'Más de 15 días antes',      result: 'Sin compensación — tu fecha se libera' },
                  { when: 'Entre 7 y 15 días',         result: 'Recibes 7% del total en tu wallet', highlight: true },
                  { when: 'Menos de 7 días o express', result: 'Recibes 17.5% del total en tu wallet', highlight: true },
                ]} />
                <Text style={s.note}>
                  La compensación reconoce que apartaste la fecha y dejaste pasar otras
                  oportunidades. Se deposita como saldo disponible en tu wallet.
                </Text>
              </PolicyCard>

              <PolicyCard icon="📍" title="No presentarse (no-show)">
                <Text style={s.body}>
                  Tu llegada se verifica por GPS. Si el grupo no se presenta a un evento
                  pagado: el pago se <Text style={s.bold}>bloquea</Text>, el cliente recibe su
                  reembolso completo, y el grupo recibe strike — con posible suspensión.
                  Usa "Voy en camino" y llega con tiempo: el traslado cuenta.
                </Text>
              </PolicyCard>

              <PolicyCard icon="🎸" title="Integrantes y talento invitado">
                <Text style={s.body}>
                  El <Text style={s.bold}>talento invitado a una sola tocada</Text> puede marcar
                  "No puedo" desde el detalle del evento si al final no le es posible asistir.
                  Los <Text style={s.bold}>integrantes fijos</Text> no cancelan por la app: lo
                  coordinan directamente con el dueño del grupo.
                </Text>
              </PolicyCard>

              <PolicyCard icon="🔒" title="Tu pago">
                <Text style={s.body}>
                  El pago del cliente queda en custodia desde que paga. Se libera el 100% a tu
                  wallet cuando el evento termina (el temporizador cierra solo al cumplirse el
                  tiempo). Los retiros se transfieren con comprobante visible en tu historial.
                </Text>
              </PolicyCard>
            </>
          )}

          {/* ── Pie legal (ambos) ── */}
          <View style={s.legalCard}>
            <Text style={s.legalTitle}>Términos de intermediación</Text>
            <Text style={s.legalText}>
              1. <Text style={s.legalBold}>Naturaleza del servicio.</Text> Daricefy es una
              plataforma tecnológica de intermediación y custodia de pagos. El contrato de
              servicios musicales se celebra directa y exclusivamente entre el cliente y el
              grupo; Daricefy no es parte de dicho contrato.{'\n\n'}
              2. <Text style={s.legalBold}>Independencia.</Text> Los grupos y talentos son
              prestadores de servicios independientes. No existe relación laboral, de
              sociedad, agencia o representación entre ellos y Daricefy.{'\n\n'}
              3. <Text style={s.legalBold}>Responsabilidades.</Text> La ejecución del servicio
              musical (calidad, puntualidad, repertorio, equipo) es responsabilidad exclusiva
              del grupo. La veracidad de la información del evento, el acceso al lugar y las
              condiciones del mismo son responsabilidad del cliente. La responsabilidad de
              Daricefy se limita a la gestión y custodia del pago conforme a estas políticas.{'\n\n'}
              4. <Text style={s.legalBold}>Aplicación automática.</Text> Los reembolsos, cargos,
              compensaciones y sanciones aquí descritos se aplican de forma automática por el
              sistema y quedan registrados con fines de auditoría.{'\n\n'}
              5. <Text style={s.legalBold}>Aceptación.</Text> Al usar Daricefy — solicitar,
              cotizar, aceptar o pagar un evento — aceptas estas políticas. Podrán actualizarse
              y la versión vigente estará siempre disponible en esta pantalla.{'\n\n'}
              6. <Text style={s.legalBold}>Disputas.</Text> Cualquier controversia entre cliente
              y grupo debe reportarse desde la app; Daricefy actúa como facilitador de la
              resolución con base en la evidencia registrada (GPS, temporizador, chat y pagos).
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

  rows: { borderRadius: RADIUS.md, borderWidth: 1, borderColor: COLORS.border, overflow: 'hidden' },
  row: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    gap: 10, paddingVertical: 10, paddingHorizontal: 12, backgroundColor: COLORS.card2,
  },
  rowDivider: { borderBottomWidth: 1, borderBottomColor: COLORS.border },
  rowWhen:   { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2, flex: 1 },
  rowResult: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.text, flex: 1.2, textAlign: 'right' },
  rowResultGreen: { color: COLORS.green },

  body: { fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.text, lineHeight: 19 },
  bold: { fontFamily: FONTS.bodySemiBold, color: COLORS.text },
  note: {
    fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted2, lineHeight: 17, marginTop: 10,
  },

  legalCard: {
    backgroundColor: 'transparent', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 16, marginTop: 4,
  },
  legalTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 12.5, color: COLORS.text, marginBottom: 8 },
  legalText: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, lineHeight: 17 },
  legalBold: { fontFamily: FONTS.bodySemiBold, color: COLORS.muted2 },
  legalDate: { fontFamily: FONTS.bodyMedium, fontSize: 10.5, color: COLORS.muted, marginTop: 10 },
});
