import React from 'react';
import {
  Alert, Image, KeyboardAvoidingView, Platform, Pressable,
  ScrollView, StyleSheet, Text, TextInput, View,
} from 'react-native';
import {
  CheckCircle, Clock, DollarSign, Info, MapPin, Scale, Truck, XCircle,
} from 'lucide-react-native';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { PHONE_WARNING } from '../../utils/phoneFilter';

// ─── Label maps ───────────────────────────────────────────────────────────────

const EVENT_TYPE_LABELS: Record<string, string> = {
  fiesta_privada: '🎉 Fiesta privada',
  boda:           '💍 Boda',
  cumpleanos:     '🎂 Cumpleaños',
  graduacion:     '🎓 Graduación',
  empresarial:    '🏢 Empresarial',
  otro:           '🎵 Otro',
};
const COVERED_LABELS: Record<string, string> = {
  si: 'Sí, está techado', no: 'No, al aire libre', no_se: 'No sabe',
};
const VENUE_LABELS: Record<string, string> = {
  patio_pequeno:         '🏡 Patio pequeño',
  salon_mediano:         '🏛️ Salón mediano',
  jardin_grande:         '🌳 Jardín grande',
  escenario_profesional: '🎤 Escenario profesional',
};
const SOUND_LABELS: Record<string, string> = {
  si: 'Sí, necesita sonido', no: 'No necesita sonido', ya_tengo: 'Ya cuenta con sonido',
};

// ─── Types ────────────────────────────────────────────────────────────────────

export type GroupMember = {
  id: string;
  full_name: string;
  avatar_url: string | null;
  isOwner: boolean;
};

export interface QuoteFormSharedProps {
  mode: 'quote' | 'propose';

  // Financial (calculated by wrapper)
  earnings: number;
  contadoPublico: number;
  commission: number;
  commPct: string;
  ownerNet: number;

  // Quote status (mode='quote')
  isReadOnly?: boolean;
  quoteStatus?: string;
  isOwner?: boolean | null;
  ownerName?: string;

  // Event info
  eventType: string;
  eventDateStr: string;
  eventTime?: string;
  durationLabel: string;
  numPersonas?: number;
  comments?: string;

  // Location — mode='quote': full address; mode='propose': zone only
  eventAddress?: string;
  eventMunicipio?: string;
  eventEstado?: string;
  onOpenMaps?: () => void;
  locationCity?: string;
  locationMunicipio?: string;
  locationEstado?: string;

  // Venue conditions
  venueCovered?: string;
  venueSize?: string;
  needsSound?: string;

  // Client card (mode='quote')
  clientName?: string;
  clientCreatedAt?: string;

  // Form state (fully controlled)
  pricePerHour: string;
  onPriceChange: (v: string) => void;
  travelCost: string;
  onTravelChange: (v: string) => void;
  overtime1h: string;
  overtime2h: string;
  overtime3h: string;
  onOt1Change: (v: string) => void;
  onOt2Change: (v: string) => void;
  onOt3Change: (v: string) => void;
  groupNotes: string;
  onNotesChange: (v: string) => void;
  notesWarn: boolean;

  // Computed display hints
  hours: number;
  pph: number;
  base: number;
  travel: number;
  ot1Val: number;
  ot2Val: number;
  ot3Val: number;
  ot1ClientPrice: number;
  ot2ClientPrice: number;
  ot3ClientPrice: number;

  // Member distribution
  groupMembers: GroupMember[];
  memberAmounts: string[];
  onMemberAmountChange: (idx: number, val: string) => void;
  onAutoDistribute?: () => void;
  numAdditional: number;

  // Propose-only
  arrivalTime?: string;
  onArrivalTimePress?: () => void;
  startTime?: string;
  onStartTimePress?: () => void;
  hasSurge?: boolean;
  isOvertimeRequired?: boolean;

  // Actions
  canSend: boolean;
  loading: boolean;
  onSend: () => void;
  onDecline?: () => void;
}

// ─── EarningsPanel (fijo fuera del scroll) ────────────────────────────────────

function EarningsPanel(p: QuoteFormSharedProps) {
  const showComm = () =>
    Alert.alert(
      'Tarifa de servicio',
      `La plataforma cobra ${p.commPct}% por la conexión con clientes, procesamiento de pago, soporte y protección anti-fraude. Tu ganancia ya tiene esta comisión descontada.`,
    );

  // Integrante (no dueño) — panel informativo reducido
  if (p.mode === 'quote' && p.isOwner === false) {
    return (
      <View style={ep.panel}>
        <Text style={ep.managerLabel}>Esta cotización la gestiona</Text>
        <Text style={ep.managerName}>{p.ownerName ?? 'el dueño del grupo'}</Text>
        {p.contadoPublico > 0 && (
          <Text style={ep.managerTotal}>Total acordado: ${p.contadoPublico.toLocaleString()} MXN</Text>
        )}
      </View>
    );
  }

  // Cancelada — sin monto
  if (p.quoteStatus === 'cancelled') {
    return (
      <View style={ep.panel}>
        <Text style={ep.cancelledLabel}>Cotización cancelada</Text>
      </View>
    );
  }

  // Rechazada — número en gris apagado
  if (p.quoteStatus === 'rejected') {
    return (
      <View style={ep.panel}>
        <Text style={ep.rejectedLabel}>Hubieras ganado</Text>
        {p.earnings > 0 && (
          <Text style={ep.rejectedAmount}>${p.earnings.toLocaleString()} MXN</Text>
        )}
      </View>
    );
  }

  // Sin precio aún — placeholder
  if (p.pph === 0) {
    return (
      <View style={ep.panel}>
        <Text style={ep.placeholder}>Escribe tu precio/hora para ver tu ganancia</Text>
      </View>
    );
  }

  const label = p.isReadOnly ? 'Ganarás' : 'Tu ganancia neta';

  return (
    <View style={ep.panel}>
      <Pressable style={ep.headerRow} onPress={p.mode === 'quote' ? showComm : undefined}>
        <Text style={ep.panelLabel}>{label}</Text>
        {p.mode === 'quote' && <Info size={14} color={COLORS.muted2} />}
      </Pressable>
      <Text style={ep.amount}>${p.earnings.toLocaleString()} MXN</Text>
      {p.mode === 'quote' && p.contadoPublico > 0 && (
        <View style={ep.subRows}>
          <View style={ep.subRow}>
            <Text style={ep.subLabel}>Cliente paga</Text>
            <Text style={ep.subVal}>${p.contadoPublico.toLocaleString()}</Text>
          </View>
          <View style={ep.subRow}>
            <Text style={ep.subLabel}>Tarifa de servicio {p.commPct}%</Text>
            <Text style={ep.subFaint}>${p.commission.toLocaleString()}</Text>
          </View>
        </View>
      )}
    </View>
  );
}

// ─── CommissionCard (dentro del scroll, modo='quote') ─────────────────────────

function CommissionCard({ commPct }: { commPct: string }) {
  const onPress = () =>
    Alert.alert(
      'Tarifa de servicio',
      `La plataforma cobra ${commPct}% por la conexión con clientes, procesamiento de pago, soporte y protección anti-fraude. Tu ganancia ya tiene esta comisión descontada.`,
    );
  return (
    <Pressable style={s.commCard} onPress={onPress}>
      <Info size={15} color={COLORS.blue} style={{ marginTop: 1 }} />
      <Text style={s.commCardText}>
        La plataforma cobra {commPct}% por conexión, procesamiento de pago y soporte. Tu ganancia ya lo tiene descontado.
      </Text>
    </Pressable>
  );
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function DetailRow({ label, value }: { label: string; value: string }) {
  return (
    <View style={s.detailRow}>
      <Text style={s.detailLabel}>{label}</Text>
      <Text style={s.detailValue}>{value}</Text>
    </View>
  );
}

function FieldLabel({ children }: { children: string }) {
  return <Text style={s.fieldLabel}>{children}</Text>;
}

// ─── QuoteFormShared ──────────────────────────────────────────────────────────

export default function QuoteFormShared(p: QuoteFormSharedProps) {
  const isReadOnly      = p.isReadOnly ?? false;
  const overtimeReqd    = p.isOvertimeRequired ?? (p.mode === 'quote');
  const formSectionTitle = p.mode === 'quote'
    ? (isReadOnly ? 'Tu cotización enviada' : 'Tu respuesta')
    : 'Tu respuesta';

  const showMemberSection =
    p.groupMembers.length > 0 || (p.numAdditional > 0 && p.mode === 'quote');

  const otPackages = [
    { label: '+1 hora extra',  val: p.ot1Val, clientPrice: p.ot1ClientPrice, value: p.overtime1h, onChange: p.onOt1Change },
    { label: '+2 horas extra', val: p.ot2Val, clientPrice: p.ot2ClientPrice, value: p.overtime2h, onChange: p.onOt2Change },
    { label: '+3 horas extra', val: p.ot3Val, clientPrice: p.ot3ClientPrice, value: p.overtime3h, onChange: p.onOt3Change },
  ];

  return (
    <View style={s.root}>
      {/* ── Panel fijo de ganancias ───────────────────────────────────── */}
      <EarningsPanel {...p} />

      <KeyboardAvoidingView style={{ flex: 1 }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
        <ScrollView contentContainerStyle={s.scroll} showsVerticalScrollIndicator={false}>

          {/* Banner de integrante (azul, informacional) */}
          {p.mode === 'quote' && p.isOwner === false && (
            <View style={s.memberBanner}>
              <Text style={s.memberBannerText}>
                Solo el dueño del grupo puede enviar el precio al cliente. Puedes ver los detalles.
              </Text>
            </View>
          )}

          {/* Tarjeta del cliente (mode='quote') */}
          {p.mode === 'quote' && p.clientName && (
            <View style={s.clientCard}>
              <Text style={s.clientEmoji}>👤</Text>
              <View>
                <Text style={s.clientName}>{p.clientName}</Text>
                {p.clientCreatedAt ? <Text style={s.clientSub}>{p.clientCreatedAt}</Text> : null}
              </View>
            </View>
          )}

          {/* Detalles del evento */}
          <View style={s.section}>
            <Text style={s.sectionTitle}>Detalles del evento</Text>
            <DetailRow label="Tipo"     value={EVENT_TYPE_LABELS[p.eventType] ?? p.eventType} />
            <DetailRow label="Fecha"    value={p.eventDateStr} />
            {p.eventTime ? <DetailRow label="Hora"     value={p.eventTime} />       : null}
            <DetailRow label="Duración" value={p.durationLabel} />
            {p.numPersonas != null ? <DetailRow label="Personas" value={`~${p.numPersonas}`} /> : null}
          </View>

          {/* Ubicación */}
          {p.mode === 'quote' && p.eventAddress ? (
            <View style={s.section}>
              <Text style={s.sectionTitle}>Ubicación</Text>
              <Pressable style={s.locationBlock} onPress={p.onOpenMaps}>
                <View style={{ flex: 1 }}>
                  <Text style={s.locationAddr}>{p.eventAddress}</Text>
                  <Text style={s.locationCity}>{p.eventMunicipio}, {p.eventEstado}</Text>
                </View>
                <View style={s.mapsBtn}>
                  <MapPin size={14} color={COLORS.green} />
                  <Text style={s.mapsBtnText}>Maps</Text>
                </View>
              </Pressable>
            </View>
          ) : p.mode === 'propose' && p.locationEstado ? (
            <View style={s.section}>
              <Text style={s.sectionTitle}>Zona del evento</Text>
              <Text style={s.locationCity}>
                📍 {p.locationCity}
                {p.locationMunicipio ? `, ${p.locationMunicipio}` : ''}, {p.locationEstado}
              </Text>
              <Text style={s.locationNote}>La dirección exacta se comparte después de confirmar el pago.</Text>
            </View>
          ) : null}

          {/* Condiciones del lugar */}
          {(p.venueCovered || p.venueSize || p.needsSound) ? (
            <View style={s.section}>
              <Text style={s.sectionTitle}>Condiciones del lugar</Text>
              {p.venueCovered ? <DetailRow label="Techado" value={COVERED_LABELS[p.venueCovered] ?? p.venueCovered} /> : null}
              {p.venueSize    ? <DetailRow label="Espacio" value={VENUE_LABELS[p.venueSize]     ?? p.venueSize}     /> : null}
              {p.needsSound   ? <DetailRow label="Sonido"  value={SOUND_LABELS[p.needsSound]   ?? p.needsSound}   /> : null}
            </View>
          ) : null}

          {/* Comentarios del cliente */}
          {p.comments ? (
            <View style={s.section}>
              <Text style={s.sectionTitle}>Comentarios del cliente</Text>
              <View style={s.commentBox}>
                <Text style={s.commentText}>"{p.comments}"</Text>
              </View>
            </View>
          ) : null}

          {/* ── Sección de respuesta / formulario ─────────────────────── */}
          <View style={s.section}>
            <Text style={s.sectionTitle}>{formSectionTitle}</Text>

            <FieldLabel>Tu precio neto por hora *</FieldLabel>
            <View style={s.currencyRow}>
              <DollarSign size={16} color={COLORS.muted2} />
              <TextInput
                style={s.currencyInput}
                placeholder="0"
                placeholderTextColor={COLORS.muted}
                value={p.pricePerHour}
                onChangeText={p.onPriceChange}
                keyboardType="numeric"
                editable={!isReadOnly}
              />
              <Text style={s.currencyUnit}>/hora</Text>
            </View>
            {p.pph > 0 && (
              <Text style={s.calcHint}>
                {p.hours}h × ${p.pph.toLocaleString()} = ${p.base.toLocaleString()} MXN
              </Text>
            )}

            <FieldLabel>Costo extra por traslado</FieldLabel>
            <View style={s.currencyRow}>
              <Truck size={16} color={COLORS.muted2} />
              <TextInput
                style={s.currencyInput}
                placeholder="0  (0 = sin costo)"
                placeholderTextColor={COLORS.muted}
                value={p.travelCost}
                onChangeText={p.onTravelChange}
                keyboardType="numeric"
                editable={!isReadOnly}
              />
            </View>

            {/* Distribución entre integrantes */}
            {showMemberSection && (
              <>
                <FieldLabel>Distribución de pago</FieldLabel>
                {!isReadOnly && (
                  <Text style={s.hint}>El dueño recibe el resto automáticamente.</Text>
                )}
                {!isReadOnly && p.numAdditional > 0 && p.earnings > 0 && p.onAutoDistribute && (
                  <Pressable style={s.autoSplitBtn} onPress={p.onAutoDistribute}>
                    <Scale size={15} color={COLORS.green} />
                    <Text style={s.autoSplitBtnText}>Distribuir equitativamente</Text>
                  </Pressable>
                )}
                <View style={s.membersList}>
                  {p.groupMembers.map((m) => {
                    const memberIdx = p.groupMembers.filter(x => !x.isOwner).indexOf(m);
                    return (
                      <View key={m.id} style={s.memberChip}>
                        {m.avatar_url ? (
                          <Image source={{ uri: m.avatar_url }} style={s.memberAvatar} />
                        ) : (
                          <View style={s.memberAvatarFallback}>
                            <Text style={s.memberAvatarInitial}>
                              {m.full_name?.charAt(0)?.toUpperCase() ?? '?'}
                            </Text>
                          </View>
                        )}
                        <View style={{ flex: 1 }}>
                          <Text style={s.memberChipName} numberOfLines={1}>{m.full_name}</Text>
                          {m.isOwner && <Text style={s.memberChipRole}>Dueño · resto auto</Text>}
                        </View>
                        {m.isOwner ? (
                          <View style={[s.currencyRow, s.memberAmountInput, s.memberOwnerCell]}>
                            <Text style={[s.currencyInput, { paddingVertical: 10, fontSize: 15, color: COLORS.green }]}>
                              {p.earnings > 0 ? p.ownerNet.toLocaleString() : '—'}
                            </Text>
                          </View>
                        ) : (
                          <View style={[s.currencyRow, s.memberAmountInput]}>
                            <DollarSign size={13} color={COLORS.muted2} />
                            <TextInput
                              style={[s.currencyInput, { fontSize: 15, paddingVertical: 8 }]}
                              placeholder="0"
                              placeholderTextColor={COLORS.muted}
                              value={p.memberAmounts[memberIdx] ?? ''}
                              onChangeText={v => p.onMemberAmountChange(memberIdx, v)}
                              keyboardType="numeric"
                              editable={!isReadOnly}
                            />
                          </View>
                        )}
                      </View>
                    );
                  })}
                  {/* Fallback mientras cargan los perfiles (mode='quote') */}
                  {p.groupMembers.length === 0 && p.numAdditional > 0 && (
                    Array.from({ length: p.numAdditional }).map((_, i) => (
                      <View key={i} style={s.memberChip}>
                        <View style={s.memberAvatarFallback}>
                          <Text style={s.memberAvatarInitial}>{i + 1}</Text>
                        </View>
                        <Text style={[s.memberChipName, { flex: 1 }]}>Integrante {i + 1}</Text>
                        <View style={[s.currencyRow, s.memberAmountInput]}>
                          <DollarSign size={13} color={COLORS.muted2} />
                          <TextInput
                            style={[s.currencyInput, { fontSize: 15, paddingVertical: 8 }]}
                            placeholder="0"
                            placeholderTextColor={COLORS.muted}
                            value={p.memberAmounts[i] ?? ''}
                            onChangeText={v => p.onMemberAmountChange(i, v)}
                            keyboardType="numeric"
                            editable={!isReadOnly}
                          />
                        </View>
                      </View>
                    ))
                  )}
                </View>
              </>
            )}

            {/* Hora de llegada / inicio (mode='propose') */}
            {p.mode === 'propose' && (
              <>
                <FieldLabel>Hora de llegada al evento *</FieldLabel>
                <Pressable
                  style={[s.currencyRow, p.arrivalTime ? s.timeSelected : null]}
                  onPress={p.onArrivalTimePress}
                >
                  <Clock size={16} color={p.arrivalTime ? COLORS.green : COLORS.muted2} />
                  <Text style={[s.currencyInput, {
                    paddingVertical: 14, fontSize: 16,
                    color: p.arrivalTime ? COLORS.green : COLORS.muted,
                  }]}>
                    {p.arrivalTime || 'Seleccionar hora'}
                  </Text>
                </Pressable>
                <Text style={[s.hint, { marginTop: -2, marginBottom: 14 }]}>
                  Hora en que llegará el grupo para instalarse.
                </Text>

                <FieldLabel>Hora de inicio de tocada</FieldLabel>
                <Pressable
                  style={[s.currencyRow, p.startTime ? s.timeSelected : null]}
                  onPress={p.onStartTimePress}
                >
                  <Clock size={16} color={p.startTime ? COLORS.green : COLORS.muted2} />
                  <Text style={[s.currencyInput, {
                    paddingVertical: 14, fontSize: 16,
                    color: p.startTime ? COLORS.green : COLORS.muted,
                  }]}>
                    {p.startTime || 'Seleccionar hora (opcional)'}
                  </Text>
                </Pressable>
                <Text style={[s.hint, { marginTop: -2, marginBottom: 14 }]}>
                  Hora en que comienza la música.
                </Text>
              </>
            )}

            {/* Notas para el cliente */}
            <FieldLabel>Notas para el cliente</FieldLabel>
            <TextInput
              style={s.notesInput}
              placeholder={'Ej: "Incluye sonido" · "No incluye transporte de equipo"'}
              placeholderTextColor={COLORS.muted}
              value={p.groupNotes}
              onChangeText={p.onNotesChange}
              multiline
              maxLength={300}
              editable={!isReadOnly}
              textAlignVertical="top"
            />
            {p.notesWarn && (
              <View style={s.contactWarnBox}>
                <Text style={s.contactWarnText}>⚠️ {PHONE_WARNING}</Text>
              </View>
            )}

            {/* Tarifa info card (solo mode='quote') */}
            {p.mode === 'quote' && <CommissionCard commPct={p.commPct} />}
          </View>

          {/* Respaldo garantizado (mode='propose', surge) */}
          {p.mode === 'propose' && p.hasSurge && (
            <View style={s.surgeRow}>
              <Text style={s.surgeLabel}>✨ Servicio con respaldo garantizado</Text>
            </View>
          )}

          {/* Paquetes de horas extra */}
          <View style={s.section}>
            <Text style={s.sectionTitle}>
              {overtimeReqd ? 'Paquetes de horas extra *' : 'Paquetes de horas extra'}
            </Text>
            {!isReadOnly && (
              <Text style={s.hint}>
                {overtimeReqd
                  ? 'Obligatorio. El cliente podrá contratar horas extra durante el evento.'
                  : 'Opcional. El cliente podrá contratar horas extra si los llenas.'}
              </Text>
            )}
            <View style={s.overtimeGrid}>
              {otPackages.map((ot) => (
                <View key={ot.label} style={s.overtimeCard}>
                  <View style={s.overtimeHeader}>
                    <Clock size={14} color={COLORS.green} />
                    <Text style={s.overtimeLabel}>{ot.label}</Text>
                    {!isReadOnly && overtimeReqd && !ot.value && (
                      <Text style={s.reqDot}>*</Text>
                    )}
                  </View>
                  <View style={s.currencyRow}>
                    <DollarSign size={14} color={COLORS.muted2} />
                    <TextInput
                      style={[s.currencyInput, { fontSize: 16 }]}
                      placeholder="0"
                      placeholderTextColor={COLORS.muted}
                      value={ot.value}
                      onChangeText={ot.onChange}
                      keyboardType="numeric"
                      editable={!isReadOnly}
                    />
                  </View>
                  {ot.val > 0 && (
                    <Text style={s.otCommNote}>
                      Tú recibirás: ${ot.val.toLocaleString()}
                      {p.mode === 'quote' && ` · Cliente pagará: $${ot.clientPrice.toLocaleString()}`}
                    </Text>
                  )}
                </View>
              ))}
            </View>
            {overtimeReqd && !isReadOnly && (!p.overtime1h || !p.overtime2h || !p.overtime3h) && (
              <View style={s.requiredNote}>
                <Text style={s.requiredNoteText}>
                  ⚠️ Debes llenar los 3 paquetes para enviar la cotización.
                </Text>
              </View>
            )}
          </View>

          {/* Banners de estado (mode='quote', read-only) */}
          {p.mode === 'quote' && isReadOnly && (
            <>
              {p.quoteStatus === 'quoted' && (
                <View style={s.quotedBanner}>
                  <CheckCircle size={16} color={COLORS.blue} />
                  <Text style={s.quotedBannerText}>
                    Cotización enviada — esperando respuesta del cliente
                  </Text>
                </View>
              )}
              {p.quoteStatus === 'accepted' && (
                <View style={[s.quotedBanner, { borderColor: 'rgba(0,230,118,0.4)', backgroundColor: 'rgba(0,230,118,0.08)' }]}>
                  <CheckCircle size={16} color={COLORS.green} />
                  <Text style={[s.quotedBannerText, { color: COLORS.green }]}>
                    El cliente aceptó tu cotización ✅
                  </Text>
                </View>
              )}
              {p.quoteStatus === 'rejected' && (
                <View style={[s.quotedBanner, { borderColor: 'rgba(239,83,80,0.4)', backgroundColor: 'rgba(239,83,80,0.08)' }]}>
                  <XCircle size={16} color={COLORS.red} />
                  <Text style={[s.quotedBannerText, { color: COLORS.red }]}>
                    Esta solicitud fue rechazada
                  </Text>
                </View>
              )}
            </>
          )}

          {/* Acciones */}
          {!isReadOnly && (
            <View style={p.mode === 'quote' ? s.actionsRow : undefined}>
              {p.mode === 'quote' && p.onDecline && (
                <Pressable style={s.declineBtn} onPress={p.onDecline}>
                  <XCircle size={18} color={COLORS.red} />
                  <Text style={s.declineBtnText}>Rechazar</Text>
                </Pressable>
              )}
              <Pressable
                style={[
                  s.sendBtn,
                  p.mode === 'quote' && s.sendBtnFlex,
                  (!p.canSend || p.loading) && s.sendBtnDisabled,
                ]}
                onPress={p.onSend}
                disabled={!p.canSend || p.loading}
              >
                <CheckCircle size={18} color={p.canSend ? COLORS.bg : COLORS.muted} />
                <Text style={[s.sendBtnText, !p.canSend && { color: COLORS.muted }]}>
                  {p.loading
                    ? 'Enviando...'
                    : p.mode === 'quote' ? 'Enviar cotización' : 'Enviar propuesta al cliente'}
                </Text>
              </Pressable>
            </View>
          )}

          <View style={{ height: 40 }} />
        </ScrollView>
      </KeyboardAvoidingView>
    </View>
  );
}

// ─── Estilos del EarningsPanel ────────────────────────────────────────────────

const ep = StyleSheet.create({
  panel: {
    backgroundColor: COLORS.card,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
    paddingHorizontal: SPACING.xl, paddingTop: 14, paddingBottom: 16,
  },
  headerRow:  { flexDirection: 'row', alignItems: 'center', gap: 6, marginBottom: 4 },
  panelLabel: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2, textTransform: 'uppercase', letterSpacing: 0.6 },
  amount:     { fontFamily: FONTS.title, fontSize: 34, color: COLORS.green, lineHeight: 42 },
  subRows:    { marginTop: 8, gap: 3 },
  subRow:     { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  subLabel:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  subVal:     { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },
  subFaint:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },

  managerLabel: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  managerName:  { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, marginTop: 2 },
  managerTotal: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginTop: 6 },

  rejectedLabel:  { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 2 },
  rejectedAmount: { fontFamily: FONTS.title, fontSize: 28, color: COLORS.muted },
  cancelledLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.muted2 },
  placeholder:    { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted, textAlign: 'center', paddingVertical: 4 },
});

// ─── Estilos del scroll ───────────────────────────────────────────────────────

const s = StyleSheet.create({
  root:   { flex: 1, backgroundColor: COLORS.bg },
  scroll: { padding: SPACING.xl },

  memberBanner: {
    backgroundColor: 'rgba(66,133,244,0.08)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.3)',
    padding: 14, marginBottom: 16,
  },
  memberBannerText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.blue, flex: 1, lineHeight: 20 },

  clientCard: {
    flexDirection: 'row', alignItems: 'center', gap: 14,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 20,
  },
  clientEmoji: { fontSize: 32 },
  clientName:  { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text },
  clientSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },

  section: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 16,
  },
  sectionTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 0.8, marginBottom: 14,
  },

  detailRow:   { flexDirection: 'row', justifyContent: 'space-between', paddingVertical: 7, borderBottomWidth: 1, borderBottomColor: COLORS.border },
  detailLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  detailValue: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, flex: 1, textAlign: 'right' },

  locationBlock: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  locationAddr:  { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },
  locationCity:  { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text, marginBottom: 6 },
  locationNote:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 18 },
  mapsBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    paddingHorizontal: 10, paddingVertical: 6,
    borderRadius: RADIUS.md, backgroundColor: COLORS.greenMuted,
    borderWidth: 1, borderColor: COLORS.green,
  },
  mapsBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green },

  commentBox:  {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border, padding: 12,
  },
  commentText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.text, lineHeight: 22, fontStyle: 'italic' },

  fieldLabel: {
    fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2,
    marginBottom: 8, marginTop: 14,
  },
  hint: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 18, marginBottom: 12 },

  currencyRow: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.card2,
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, marginBottom: 4,
  },
  currencyInput: {
    flex: 1, paddingVertical: 13,
    fontFamily: FONTS.bodySemiBold, fontSize: 18, color: COLORS.text,
  },
  currencyUnit: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  calcHint:     { fontFamily: FONTS.body, fontSize: 12, color: COLORS.green, marginBottom: 4, marginTop: 2 },

  membersList:         { gap: 8, marginBottom: 12, marginTop: 8 },
  memberChip: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.bg, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 12, paddingVertical: 8,
  },
  memberAvatar:         { width: 36, height: 36, borderRadius: 18 },
  memberAvatarFallback: {
    width: 36, height: 36, borderRadius: 18,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  memberAvatarInitial: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.green },
  memberChipName:      { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  memberChipRole:      { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 1 },
  memberAmountInput:   { flex: 0, width: 110, marginBottom: 0 },
  memberOwnerCell:     { borderColor: 'rgba(0,230,118,0.3)', backgroundColor: 'rgba(0,230,118,0.05)' },

  autoSplitBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.green,
    backgroundColor: 'rgba(0,230,118,0.07)',
    paddingVertical: 11, marginBottom: 12,
  },
  autoSplitBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },

  notesInput: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 13,
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.text,
    minHeight: 80, marginBottom: 4,
  },

  contactWarnBox: {
    backgroundColor: 'rgba(255,179,0,0.10)', borderRadius: RADIUS.sm,
    borderWidth: 1, borderColor: 'rgba(255,179,0,0.35)',
    paddingHorizontal: 12, paddingVertical: 9, marginTop: 6,
  },
  contactWarnText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: '#FFB300', lineHeight: 17 },

  commCard: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 10,
    backgroundColor: 'rgba(66,133,244,0.06)', borderRadius: RADIUS.sm,
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.18)',
    paddingHorizontal: 12, paddingVertical: 10, marginTop: 14,
  },
  commCardText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, flex: 1, lineHeight: 19 },

  timeSelected: { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.06)' },

  surgeRow: {
    paddingVertical: 7, paddingHorizontal: 12,
    backgroundColor: 'rgba(0,230,118,0.07)',
    borderRadius: RADIUS.md, marginBottom: 6,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.20)',
  },
  surgeLabel: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },

  overtimeGrid:   { gap: 10 },
  overtimeCard: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 12,
  },
  overtimeHeader: { flexDirection: 'row', alignItems: 'center', gap: 6, marginBottom: 8 },
  overtimeLabel:  { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, flex: 1 },
  reqDot:         { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.red },
  otCommNote:     { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 4 },
  requiredNote: {
    marginTop: 10, padding: 10, borderRadius: RADIUS.md,
    backgroundColor: 'rgba(255,152,0,0.08)', borderWidth: 1, borderColor: 'rgba(255,152,0,0.4)',
  },
  requiredNoteText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: 'rgba(255,152,0,1)' },

  quotedBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    padding: 14, borderRadius: RADIUS.lg, borderWidth: 1,
    borderColor: 'rgba(66,133,244,0.4)', backgroundColor: 'rgba(66,133,244,0.08)',
    marginBottom: 12,
  },
  quotedBannerText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.blue, flex: 1 },

  actionsRow:  { flexDirection: 'row', gap: 12, marginTop: 8, marginBottom: 12 },
  declineBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    flex: 1, paddingVertical: 15, borderRadius: RADIUS.lg, borderWidth: 1,
    borderColor: 'rgba(239,83,80,0.4)', backgroundColor: 'rgba(239,83,80,0.08)',
  },
  declineBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.red },

  sendBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    paddingVertical: 15, borderRadius: RADIUS.lg, backgroundColor: COLORS.green,
    marginTop: 8, marginBottom: 12,
  },
  sendBtnFlex:     { flex: 2, marginTop: 0, marginBottom: 0 },
  sendBtnDisabled: { opacity: 0.4 },
  sendBtnText:     { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },
});
