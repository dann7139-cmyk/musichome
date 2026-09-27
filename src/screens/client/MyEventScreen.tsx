// ─────────────────────────────────────────────────────────────────────────────
// MyEventScreen — Fase 2: "Mi Evento" como centro de organización
//
// Dashboard de UN evento. Lee todo de client_get_event_dashboard (sql/692), que
// es SOLO LECTURA y deriva los totales de `reservations`. No hay ningún cálculo
// de dinero en esta pantalla: la aritmética vive en el servidor, en un solo
// lugar auditable.
//
// ── Reglas de dinero que la pantalla respeta (no las inventa) ───────────────
//   · events.total_price NO es fuente financiera y no se lee.
//   · Contratado sale de reservas activas (excluye cancelada/rechazada/expirada).
//   · Pagado es dinero REALMENTE entrado; un anticipo cuenta solo por su monto.
//   · Pendiente = contratado − pagado.
//   · Las monedas NUNCA se suman: un bloque independiente por moneda.
//   · El presupuesto es informativo. Rebasarlo avisa, no bloquea nada.
//   · No incluye regalos, propinas ni horas extra — se dice explícitamente.
//
// ── Reutiliza ──────────────────────────────────────────────────────────────
// theme.ts, Button, formatCurrency() de utils/calculations, PROVIDER_CATEGORIES
// para nombrar categorías, el header estándar de FORMULARIO, y las rutas que ya
// existen: EventCategoryPicker (hub de servicios) y EventInfo (editar datos).
// Sin librerías nuevas.
// ─────────────────────────────────────────────────────────────────────────────
import { ArrowLeft, CalendarDays, Clock, MapPin, Pencil, Users } from 'lucide-react-native';
import React, { useCallback, useState } from 'react';
import {
  ActivityIndicator,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useFocusEffect } from '@react-navigation/native';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Button from '../../components/ui/Button';
import { formatCurrency } from '../../utils/calculations';
import { PROVIDER_CATEGORIES } from '../../constants/providerCategories';

// formatCurrency() solo tipa 'MXN' | 'USD'. Este envoltorio respeta su formato
// para esas dos y, para cualquier otro código real (CAD hoy), escribe el monto
// con su código — nunca un "$" ambiguo, que es justo la regla que documenta
// formatCurrency.
function money(amount: number | string | null | undefined, code?: string | null): string {
  const n = Number(amount ?? 0);
  if (code === 'MXN' || code === 'USD') return formatCurrency(n, code);
  const fmt = n.toLocaleString('es-MX', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return code ? `$${fmt} ${code}` : `$${fmt}`;
}

// Estados de reserva que el cliente entiende como "ya es mío".
const CONTRACTED_LOOK = ['accepted', 'confirmed', 'in_progress', 'completed'];

export default function MyEventScreen({ route, navigation }: any) {
  const { t, i18n } = useTranslation();
  const { eventId } = route?.params ?? {};
  const dateLocale = i18n.language?.startsWith('en') ? 'en-US' : 'es-MX';

  const [data, setData]         = useState<any>(null);
  const [loading, setLoading]   = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [errorKey, setErrorKey] = useState<string | null>(null);

  const fetchDashboard = useCallback(async () => {
    if (!eventId) { setErrorKey('myEvent.errors.notFound'); setLoading(false); return; }
    const { data: res, error } = await supabase.rpc('client_get_event_dashboard', { p_event_id: eventId });
    if (error || !res?.ok) {
      const code = res?.error ?? error?.message ?? '';
      setErrorKey(
        code.includes('event_not_owned_by_client') ? 'myEvent.errors.notOwner'
        : code.includes('event_not_found')         ? 'myEvent.errors.notFound'
        : code.includes('not_authenticated')       ? 'myEvent.errors.noSession'
        : 'myEvent.errors.generic',
      );
      setData(null);
    } else {
      setErrorKey(null);
      setData(res);
    }
    setLoading(false);
  }, [eventId]);

  useFocusEffect(useCallback(() => { fetchDashboard(); }, [fetchDashboard]));

  const onRefresh = async () => { setRefreshing(true); await fetchDashboard(); setRefreshing(false); };

  const ev        = data?.event;
  const services  = (data?.services ?? []) as any[];
  const totals    = (data?.totals_by_currency ?? []) as any[];
  const budget    = data?.budget ?? null;
  const limit     = Number(data?.provider_limit ?? 20);
  const count     = Number(data?.provider_count ?? 0);
  const hayCupo   = count < limit;

  const contratados = services.filter(x => x.kind === 'reservation' && x.counts_as_contracted);
  const cotizando   = services.filter(x => x.kind === 'quote');
  const inactivos   = services.filter(x => x.kind === 'reservation' && !x.counts_as_contracted);

  const prettyDate = ev?.event_date
    ? new Date(ev.event_date + 'T12:00:00').toLocaleDateString(dateLocale, { day: 'numeric', month: 'long', year: 'numeric' })
    : '—';
  const horario = [ev?.event_time?.substring(0, 5), ev?.end_time?.substring(0, 5)].filter(Boolean).join(' – ');
  const ubicacion = [ev?.event_municipio, ev?.event_estado].filter(Boolean).join(', ');

  const categoryLabel = (key: string | null) => {
    const cat = PROVIDER_CATEGORIES.find(c => c.key === key);
    return cat ? t(cat.labelKey) : null;
  };

  const irAlHub = () => navigation.navigate('EventCategoryPicker', {
    eventId,
    eventDate:    ev?.event_date ?? null,
    eventAddress: ev?.address ?? null,
  });

  // ── Estados de carga y error ──────────────────────────────────────────────
  if (loading) {
    return (
      <View style={s.root}>
        <Header navigation={navigation} title={t('myEvent.headerTitle')} sub={null} />
        <View style={s.center}><ActivityIndicator color={COLORS.green} /></View>
      </View>
    );
  }
  if (errorKey || !ev) {
    return (
      <View style={s.root}>
        <Header navigation={navigation} title={t('myEvent.headerTitle')} sub={null} />
        <View style={s.center}>
          <Text style={s.muted}>{t(errorKey ?? 'myEvent.errors.generic')}</Text>
        </View>
      </View>
    );
  }

  return (
    <View style={s.root}>
      <Header
        navigation={navigation}
        title={ev.name || t('myEvent.headerTitle')}
        sub={ev.name ? prettyDate : null}
        onEdit={() => navigation.navigate('EventInfo', { eventId })}
      />

      <ScrollView
        contentContainerStyle={s.scroll}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
      >
        {/* ── Ficha del evento ─────────────────────────────────────────────── */}
        <View style={s.heroCard}>
          {!ev.name && <Text style={s.heroTitle}>{t('myEvent.untitled')}</Text>}
          <View style={s.heroRow}>
            <CalendarDays size={15} color={COLORS.green} />
            <Text style={s.heroText}>{prettyDate}</Text>
          </View>
          {!!horario && (
            <View style={s.heroRow}>
              <Clock size={15} color={COLORS.muted2} />
              <Text style={s.heroText}>{horario}</Text>
            </View>
          )}
          {!!ev.address && (
            <View style={s.heroRow}>
              <MapPin size={15} color={COLORS.muted2} />
              <Text style={s.heroText} numberOfLines={2}>
                {ev.address}{ubicacion ? ` · ${ubicacion}` : ''}
              </Text>
            </View>
          )}
          {!!ev.guest_count && (
            <View style={s.heroRow}>
              <Users size={15} color={COLORS.muted2} />
              <Text style={s.heroText}>{t('myEvent.guests', { count: ev.guest_count })}</Text>
            </View>
          )}
          {!!ev.event_type && (
            <View style={s.typePill}>
              <Text style={s.typePillText}>{t(`quoteFormScreen.eventTypes.${ev.event_type}`)}</Text>
            </View>
          )}
          {/* Invita a completar lo que falte, sin regañar */}
          {(!ev.name || !ev.guest_count || ev.budget_max == null) && (
            <Pressable style={s.completeRow} onPress={() => navigation.navigate('EventInfo', { eventId })}>
              <Pencil size={13} color={COLORS.green} />
              <Text style={s.completeText}>{t('myEvent.completeInfo')}</Text>
            </Pressable>
          )}
        </View>

        {/* ── Presupuesto (informativo) ────────────────────────────────────── */}
        {!!budget && (
          <View style={[s.card, budget.over_budget && s.cardWarn]}>
            <Text style={s.cardTitle}>{t('myEvent.budgetTitle')}</Text>
            <View style={s.lineRow}>
              <Text style={s.lineLabel}>{t('myEvent.budgetMax')}</Text>
              <Text style={s.lineValue}>{money(budget.budget_max, budget.currency_code)}</Text>
            </View>
            <View style={s.lineRow}>
              <Text style={s.lineLabel}>{t('myEvent.contracted')}</Text>
              <Text style={s.lineValue}>{money(budget.contracted, budget.currency_code)}</Text>
            </View>
            <View style={[s.lineRow, s.lineRowLast]}>
              <Text style={s.lineLabelStrong}>
                {budget.over_budget ? t('myEvent.budgetOver') : t('myEvent.budgetLeft')}
              </Text>
              <Text style={[s.lineValueStrong, budget.over_budget ? s.valueWarn : s.valueGood]}>
                {money(Math.abs(Number(budget.remaining ?? 0)), budget.currency_code)}
              </Text>
            </View>
            <Text style={s.cardNote}>
              {budget.over_budget ? t('myEvent.budgetOverNote') : t('myEvent.budgetNote')}
            </Text>
          </View>
        )}

        {/* ── Totales por moneda ───────────────────────────────────────────── */}
        {totals.length > 0 && (
          <>
            <Text style={s.sectionTitle}>{t('myEvent.moneyTitle')}</Text>
            {totals.length > 1 && <Text style={s.sectionSub}>{t('myEvent.multiCurrencyNote')}</Text>}
            {totals.map(tot => (
              <View key={tot.currency_code} style={s.card}>
                {totals.length > 1 && <Text style={s.currencyBadge}>{tot.currency_code}</Text>}
                <View style={s.lineRow}>
                  <Text style={s.lineLabel}>{t('myEvent.contracted')}</Text>
                  <Text style={s.lineValue}>{money(tot.contracted, tot.currency_code)}</Text>
                </View>
                <View style={s.lineRow}>
                  <Text style={s.lineLabel}>{t('myEvent.paid')}</Text>
                  <Text style={[s.lineValue, s.valueGood]}>{money(tot.paid, tot.currency_code)}</Text>
                </View>
                <View style={[s.lineRow, s.lineRowLast]}>
                  <Text style={s.lineLabelStrong}>{t('myEvent.pending')}</Text>
                  <Text style={s.lineValueStrong}>{money(tot.pending, tot.currency_code)}</Text>
                </View>
              </View>
            ))}
            <Text style={s.scopeNote}>{t('myEvent.scopeNote')}</Text>
          </>
        )}

        {/* ── Lo que ya tengo ──────────────────────────────────────────────── */}
        <Text style={s.sectionTitle}>
          {t('myEvent.mineTitle')}{contratados.length > 0 ? ` · ${contratados.length}` : ''}
        </Text>
        {contratados.length === 0 ? (
          // La tarjeta grande de "todavia no agregaste nada" SOLO cuando de
          // verdad no hay nada. Si ya pidio cotizaciones (el caso normal justo
          // despues de armar la fiesta) o si todo quedo cancelado, decir "no has
          // agregado ningun servicio" se contradice con la lista de abajo.
          services.length === 0 ? (
            <View style={s.emptyCard}>
              <Text style={s.emptyEmoji}>🎉</Text>
              <Text style={s.emptyTitle}>{t('myEvent.emptyTitle')}</Text>
              <Text style={s.emptyText}>{t('myEvent.emptyText')}</Text>
            </View>
          ) : (
            <Text style={s.sectionSub}>{t('myEvent.noneConfirmedYet')}</Text>
          )
        ) : (
          contratados.map(sv => <ServiceRow key={sv.id} sv={sv} t={t} categoryLabel={categoryLabel} />)
        )}

        {/* ── Esperando respuesta ──────────────────────────────────────────── */}
        {cotizando.length > 0 && (
          <>
            <Text style={s.sectionTitle}>{t('myEvent.waitingTitle')} · {cotizando.length}</Text>
            <Text style={s.sectionSub}>{t('myEvent.waitingNote')}</Text>
            {cotizando.map(sv => <ServiceRow key={sv.id} sv={sv} t={t} categoryLabel={categoryLabel} />)}
          </>
        )}

        {/* ── Ya no cuentan ────────────────────────────────────────────────── */}
        {inactivos.length > 0 && (
          <>
            <Text style={s.sectionTitle}>{t('myEvent.inactiveTitle')}</Text>
            <Text style={s.sectionSub}>{t('myEvent.inactiveNote')}</Text>
            {inactivos.map(sv => <ServiceRow key={sv.id} sv={sv} t={t} categoryLabel={categoryLabel} muted />)}
          </>
        )}

        {/* ── Agregar más ──────────────────────────────────────────────────── */}
        <View style={{ height: 8 }} />
        {hayCupo ? (
          <>
            <Button label={t('myEvent.addService')} onPress={irAlHub} />
            <Text style={s.footerNote}>
              {t('myEvent.slots', { count, limit })}
            </Text>
          </>
        ) : (
          <View style={s.card}>
            <Text style={s.cardTitle}>{t('myEvent.fullTitle')}</Text>
            <Text style={s.cardNote}>{t('myEvent.fullNote', { limit })}</Text>
          </View>
        )}
        <View style={{ height: 40 }} />
      </ScrollView>
    </View>
  );
}

// ── Header estándar de FORMULARIO (theme.ts) con lápiz opcional ────────────
function Header({ navigation, title, sub, onEdit }: any) {
  return (
    <SafeAreaView edges={['top']} style={s.header}>
      <Pressable style={s.backBtn} onPress={() => navigation.goBack()} hitSlop={6}>
        <ArrowLeft size={20} color={COLORS.text} />
      </Pressable>
      <View style={{ flex: 1 }}>
        <Text style={s.headerTitle} numberOfLines={1}>{title}</Text>
        {!!sub && <Text style={s.headerSub}>{sub}</Text>}
      </View>
      {!!onEdit && (
        <Pressable style={s.editBtn} onPress={onEdit} hitSlop={6}>
          <Pencil size={14} color={COLORS.muted2} />
        </Pressable>
      )}
    </SafeAreaView>
  );
}

// ── Un servicio (reserva o cotización) ────────────────────────────────────
function ServiceRow({ sv, t, categoryLabel, muted }: any) {
  const cat = categoryLabel(sv.category_key);
  const esReserva = sv.kind === 'reservation';
  const pagado = Number(sv.paid_amount ?? 0);
  const total  = Number(sv.total_price ?? 0);
  const estadoKey = esReserva ? `myEvent.status.${sv.status}` : `myEvent.quoteStatus.${sv.status}`;
  const verde = esReserva && CONTRACTED_LOOK.includes(sv.status) && pagado > 0 && pagado >= total;

  return (
    <View style={[s.serviceCard, muted && s.serviceCardMuted]}>
      <View style={s.serviceTop}>
        <View style={{ flex: 1 }}>
          <Text style={s.serviceName} numberOfLines={1}>{sv.group_name}</Text>
          <Text style={s.serviceMeta} numberOfLines={1}>
            {[cat, sv.group_genre].filter(Boolean).join(' · ')}
          </Text>
        </View>
        <View style={[s.statusPill, verde && s.statusPillGood, !esReserva && s.statusPillQuote]}>
          <Text style={[s.statusPillText, verde && s.statusPillTextGood, !esReserva && s.statusPillTextQuote]}>
            {t(estadoKey, t(esReserva ? 'myEvent.status.unknown' : 'myEvent.quoteStatus.unknown'))}
          </Text>
        </View>
      </View>
      <View style={s.serviceMoney}>
        <Text style={s.serviceTotal}>{money(total, sv.currency_code)}</Text>
        {esReserva && (
          <Text style={s.servicePaid}>
            {pagado > 0
              ? t('myEvent.paidOf', { paid: money(pagado, sv.currency_code) })
              : t('myEvent.notPaidYet')}
          </Text>
        )}
      </View>
    </View>
  );
}

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: COLORS.bg },

  header: {
    flexDirection: 'row', alignItems: 'center', gap: 14,
    paddingHorizontal: SPACING.xl, paddingVertical: 12,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  editBtn: {
    width: 32, height: 32, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  headerSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 1 },

  center: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: SPACING.xl },
  muted:  { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center' },
  scroll: { padding: SPACING.xl, paddingBottom: 60 },

  // Ficha del evento
  heroCard: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    padding: 16, gap: 8,
  },
  heroTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  heroRow:   { flexDirection: 'row', alignItems: 'center', gap: 9 },
  heroText:  { flex: 1, fontFamily: FONTS.body, fontSize: 13.5, color: COLORS.text, lineHeight: 19 },
  typePill: {
    alignSelf: 'flex-start', marginTop: 2,
    backgroundColor: 'rgba(0,230,118,0.12)', borderRadius: RADIUS.full,
    paddingHorizontal: 11, paddingVertical: 5,
  },
  typePillText: { fontFamily: FONTS.bodySemiBold, fontSize: 11.5, color: COLORS.green },
  completeRow: {
    flexDirection: 'row', alignItems: 'center', gap: 7, marginTop: 6,
    paddingTop: 10, borderTopWidth: 1, borderTopColor: COLORS.border,
  },
  completeText: { fontFamily: FONTS.bodyMedium, fontSize: 12.5, color: COLORS.green },

  sectionTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text,
    marginTop: 24, marginBottom: 12,
  },
  sectionSub: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: -6, marginBottom: 12, lineHeight: 17 },

  // Tarjetas de dinero
  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 16, marginBottom: 10,
  },
  cardWarn:  { borderColor: 'rgba(255,179,0,0.45)' },
  cardTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, marginBottom: 12 },
  cardNote:  { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 10, lineHeight: 16 },
  currencyBadge: {
    alignSelf: 'flex-start', marginBottom: 10,
    fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.muted2,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.full,
    paddingHorizontal: 10, paddingVertical: 4, overflow: 'hidden',
  },
  lineRow: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    gap: 12, paddingVertical: 7,
  },
  lineRowLast: { borderTopWidth: 1, borderTopColor: COLORS.border, marginTop: 4, paddingTop: 11 },
  lineLabel:       { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  lineLabelStrong: { fontFamily: FONTS.bodySemiBold, fontSize: 13.5, color: COLORS.text },
  lineValue:       { fontFamily: FONTS.bodyMedium, fontSize: 13.5, color: COLORS.text, textAlign: 'right' },
  lineValueStrong: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, textAlign: 'right' },
  valueGood: { color: COLORS.green },
  valueWarn: { color: COLORS.gold },
  scopeNote: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, lineHeight: 16, marginTop: 2 },

  // Servicios
  serviceCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 14, marginBottom: 10, gap: 10,
  },
  serviceCardMuted: { opacity: 0.55 },
  serviceTop:   { flexDirection: 'row', alignItems: 'flex-start', gap: 10 },
  serviceName:  { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  serviceMeta:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2 },
  serviceMoney: {
    flexDirection: 'row', alignItems: 'baseline', justifyContent: 'space-between',
    gap: 10, borderTopWidth: 1, borderTopColor: COLORS.border, paddingTop: 10,
  },
  serviceTotal: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  servicePaid:  { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted2, textAlign: 'right', flexShrink: 1 },
  statusPill: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.full,
    paddingHorizontal: 10, paddingVertical: 5, maxWidth: 140,
  },
  statusPillGood:      { backgroundColor: 'rgba(0,230,118,0.12)' },
  statusPillQuote:     { backgroundColor: 'rgba(255,152,0,0.12)' },
  statusPillText:      { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.muted2 },
  statusPillTextGood:  { color: COLORS.green },
  statusPillTextQuote: { color: COLORS.orange },

  // Vacío
  emptyCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 24, alignItems: 'center', gap: 8,
  },
  emptyEmoji: { fontSize: 30 },
  emptyTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, textAlign: 'center' },
  emptyText:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, textAlign: 'center', lineHeight: 19 },

  footerNote: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 10, textAlign: 'center' },
});
