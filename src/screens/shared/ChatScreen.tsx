import React, { useEffect, useRef, useState } from 'react';
import {
  Alert,
  FlatList,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ArrowLeft, Send, AlertTriangle } from 'lucide-react-native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { analyzeMessage, PHONE_WARNING } from '../../utils/phoneFilter';

interface Message {
  id: string;
  sender_id: string;
  sender_name: string;
  sender_role: 'group' | 'client';
  content: string;
  created_at: string;
}

export default function ChatScreen({ route, navigation }: any) {
  const { reservation, senderRole } = route.params as {
    reservation: any;
    senderRole: 'group' | 'client';
  };

  const [messages, setMessages] = useState<Message[]>([]);
  const [input, setInput] = useState('');
  const [senderId, setSenderId] = useState<string | null>(null);
  const [senderName, setSenderName] = useState('');
  const [phoneWarning, setPhoneWarning] = useState(false);
  const [sending, setSending] = useState(false);
  const [liveRes, setLiveRes] = useState(reservation);
  const listRef = useRef<FlatList>(null);
  const receiverIdRef = useRef<string | null>(null);
  const violationCountRef = useRef(0);

  // Cargar reserva fresca de DB para tener status/payment_status/client_id actualizados
  useEffect(() => {
    supabase
      .from('reservations')
      .select('id, status, payment_status, group_arrived_at, event_ended_at, client_id, group_id')
      .eq('id', reservation.id)
      .single()
      .then(({ data }) => { if (data) setLiveRes((prev: any) => ({ ...prev, ...data })); });
  }, []);

  const isOpen = !!liveRes.group_arrived_at
    && !liveRes.event_ended_at
    && (
      liveRes.payment_status === 'paid'
      || liveRes.payment_status === 'deposit_paid'
      || liveRes.payment_status === 'fully_paid'
      || liveRes.status === 'in_progress'
      || liveRes.status === 'confirmed'
    );

  const otherPartyName = senderRole === 'group'
    ? (reservation.client?.full_name ?? 'Cliente')
    : (reservation.group?.name ?? 'Grupo');

  // ── Cargar usuario y mensajes ──────────────────────────────────────────────
  useEffect(() => {
    loadUser();
    loadMessages();
    const channel = subscribeRealtime();
    return () => { supabase.removeChannel(channel); };
  }, []);

  const loadUser = async () => {
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) return;
    setSenderId(user.id);
    const { data: profile } = await supabase
      .from('profiles')
      .select('full_name')
      .eq('id', user.id)
      .single();
    setSenderName(profile?.full_name ?? 'Usuario');

    // Obtener el ID del receptor para notificaciones
    if (senderRole === 'client') {
      // Cliente → notificar al dueño del grupo
      const groupId = reservation.group_id ?? liveRes.group_id;
      if (groupId) {
        const { data: grp } = await supabase
          .from('groups')
          .select('owner_id')
          .eq('id', groupId)
          .single();
        if (grp?.owner_id) receiverIdRef.current = grp.owner_id;
      }
    } else {
      // Grupo → notificar al cliente (buscar en DB si no está en route params)
      const clientId = reservation.client_id ?? liveRes.client_id;
      if (clientId) {
        receiverIdRef.current = clientId;
      } else {
        const { data: res } = await supabase
          .from('reservations')
          .select('client_id')
          .eq('id', reservation.id)
          .single();
        if (res?.client_id) receiverIdRef.current = res.client_id;
      }
    }
  };

  const loadMessages = async () => {
    const { data } = await supabase
      .from('reservation_messages')
      .select('*')
      .eq('reservation_id', reservation.id)
      .order('created_at', { ascending: true });
    if (data) setMessages(data as Message[]);
  };

  const subscribeRealtime = () => {
    const channel = supabase
      .channel(`chat:${reservation.id}`)
      .on(
        'postgres_changes',
        {
          event: 'INSERT',
          schema: 'public',
          table: 'reservation_messages',
          filter: `reservation_id=eq.${reservation.id}`,
        },
        (payload) => {
          setMessages(prev => [...prev, payload.new as Message]);
          setTimeout(() => listRef.current?.scrollToEnd({ animated: true }), 100);
        },
      )
      .subscribe();
    return channel;
  };

  // ── Enviar mensaje ─────────────────────────────────────────────────────────
  const handleSend = async () => {
    const text = input.trim();
    if (!text || !senderId || !senderName) return;

    const filterResult = analyzeMessage(text);
    if (filterResult.blocked) {
      setPhoneWarning(true);
      violationCountRef.current += 1;
      if (senderId) {
        supabase.from('contact_violation_logs').insert({
          reservation_id:    reservation.id,
          user_id:           senderId,
          sender_role:       senderRole,
          attempted_message: text,
          violation_type:    filterResult.type!,
          detected_pattern:  filterResult.pattern ?? null,
        });
        if (violationCountRef.current >= 3) {
          void supabase.rpc('log_fraud_signal', {
            p_user_id:    senderId,
            p_signal_type: 'chat_phone_bypass',
            p_details:    { reservation_id: reservation.id, attempts: violationCountRef.current },
          });
        }
      }
      return;
    }

    setSending(true);
    setPhoneWarning(false);

    const { error } = await supabase.from('reservation_messages').insert({
      reservation_id: reservation.id,
      sender_id:      senderId,
      sender_name:    senderName,
      sender_role:    senderRole,
      content:        text,
    });

    if (error) {
      Alert.alert('Error', 'No se pudo enviar el mensaje.');
    } else {
      setInput('');
      // Notificar al receptor (buscar en el momento si el ref no está listo)
      const notifBody = text.length > 80 ? text.slice(0, 77) + '...' : text;
      const notifData = { reservation_id: reservation.id, screen: 'Chat' };

      if (senderRole === 'client') {
        // Cliente → notificar a owner + miembros del grupo
        const groupId = liveRes.group_id ?? reservation.group_id;
        if (groupId) {
          const { data: grp } = await supabase
            .from('groups').select('owner_id').eq('id', groupId).single();
          const ownerId = grp?.owner_id ?? receiverIdRef.current;
          if (ownerId) {
            const notifs: any[] = [
              { user_id: ownerId, type: 'chat', title: `💬 Mensaje del cliente`, body: notifBody, data: notifData },
            ];
            const { data: members } = await supabase
              .from('job_invitations')
              .select('invited_user_id')
              .eq('group_id', groupId)
              .eq('status', 'accepted')
              .in('invitation_type', ['membership', 'job']);
            (members ?? []).forEach((m: any) => {
              if (m.invited_user_id !== ownerId) {
                notifs.push({ user_id: m.invited_user_id, type: 'chat', title: `💬 Mensaje del cliente`, body: notifBody, data: notifData });
              }
            });
            supabase.from('notifications').insert(notifs);
          }
        }
      } else {
        // Grupo → notificar al cliente
        const clientId = liveRes.client_id ?? reservation.client_id ?? receiverIdRef.current;
        if (clientId) {
          supabase.from('notifications').insert([{
            user_id: clientId,
            type: 'chat',
            title: `💬 Mensaje del grupo`,
            body: notifBody,
            data: notifData,
          }]);
        } else {
          // Último fallback: buscar en DB
          supabase.from('reservations').select('client_id').eq('id', reservation.id).single()
            .then(({ data: res }) => {
              if (res?.client_id) {
                supabase.from('notifications').insert([{
                  user_id: res.client_id, type: 'chat',
                  title: `💬 Mensaje del grupo`, body: notifBody, data: notifData,
                }]);
              }
            });
        }
      }
    }
    setSending(false);
  };

  // ── Render ─────────────────────────────────────────────────────────────────
  return (
    <View style={s.root}>
      <SafeAreaView style={s.header} edges={['top']}>
        <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <View style={s.headerCenter}>
          <Text style={s.headerTitle}>Chat con {otherPartyName}</Text>
          <Text style={s.headerSub}>
            {isOpen ? '🟢 Chat activo durante el evento' : '⚫ Chat cerrado'}
          </Text>
        </View>
        <View style={{ width: 40 }} />
      </SafeAreaView>

      {/* Chat cerrado */}
      {!isOpen && (
        <View style={s.closedBanner}>
          <Text style={s.closedIcon}>🔒</Text>
          <Text style={s.closedTitle}>
            {reservation.event_ended_at
              ? 'El evento terminó'
              : 'Chat no disponible aún'}
          </Text>
          <Text style={s.closedSub}>
            {reservation.event_ended_at
              ? 'Los mensajes se eliminaron al finalizar el evento.'
              : 'El chat se abre cuando el grupo marque "Llegué" y el pago esté confirmado.'}
          </Text>
        </View>
      )}

      {isOpen && (
        <KeyboardAvoidingView
          style={s.flex}
          behavior={Platform.OS === 'ios' ? 'padding' : undefined}
          keyboardVerticalOffset={Platform.OS === 'ios' ? 90 : 0}
        >
          {/* Messages list */}
          <FlatList
            ref={listRef}
            data={messages}
            keyExtractor={m => m.id}
            contentContainerStyle={s.list}
            onContentSizeChange={() => listRef.current?.scrollToEnd({ animated: false })}
            ListEmptyComponent={
              <View style={s.emptyChat}>
                <Text style={s.emptyChatText}>Sin mensajes aún.</Text>
                <Text style={s.emptyChatSub}>Coordina los detalles del evento aquí.</Text>
              </View>
            }
            renderItem={({ item }) => {
              const isMe = item.sender_id === senderId;
              return (
                <View style={[s.bubbleWrap, isMe && s.bubbleWrapMe]}>
                  {!isMe && (
                    <Text style={s.bubbleSender}>{item.sender_name}</Text>
                  )}
                  <View style={[s.bubble, isMe ? s.bubbleMe : s.bubbleThem]}>
                    <Text style={[s.bubbleText, isMe && s.bubbleTextMe]}>
                      {item.content}
                    </Text>
                  </View>
                  <Text style={[s.bubbleTime, isMe && s.bubbleTimeMe]}>
                    {new Date(item.created_at).toLocaleTimeString('es-MX', {
                      hour: '2-digit',
                      minute: '2-digit',
                    })}
                  </Text>
                </View>
              );
            }}
          />

          {/* Phone warning */}
          {phoneWarning && (
            <View style={s.warningBanner}>
              <AlertTriangle size={16} color={COLORS.orange} />
              <Text style={s.warningText}>{PHONE_WARNING}</Text>
            </View>
          )}

          {/* Security note */}
          <View style={s.securityNote}>
            <Text style={s.securityNoteText}>
              🛡 Datos de contacto bloqueados · Chat se borra al terminar el evento
            </Text>
          </View>

          {/* Input */}
          <View style={s.inputRow}>
            <TextInput
              style={s.input}
              placeholder="Escribe un mensaje..."
              placeholderTextColor={COLORS.muted}
              value={input}
              onChangeText={t => { setInput(t); setPhoneWarning(false); }}
              maxLength={500}
              multiline
            />
            <Pressable
              style={[s.sendBtn, (!input.trim() || sending) && s.sendBtnDisabled]}
              onPress={handleSend}
              disabled={!input.trim() || sending}
            >
              <Send size={18} color={input.trim() ? COLORS.bg : COLORS.muted} />
            </Pressable>
          </View>
        </KeyboardAvoidingView>
      )}
    </View>
  );
}

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: COLORS.bg },
  flex: { flex: 1 },

  // ── Header ──────────────────────────────────────────────────────────────────
  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingVertical: 12,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerCenter: { flex: 1, alignItems: 'center' },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  headerSub: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 1 },

  // ── Closed state ────────────────────────────────────────────────────────────
  closedBanner: {
    flex: 1, alignItems: 'center', justifyContent: 'center',
    paddingHorizontal: 40, gap: 8,
  },
  closedIcon: { fontSize: 40, marginBottom: 8 },
  closedTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text, textAlign: 'center' },
  closedSub: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, textAlign: 'center', lineHeight: 20 },

  // ── Messages ─────────────────────────────────────────────────────────────────
  list: { padding: SPACING.xl, gap: 12, flexGrow: 1 },
  emptyChat: { flex: 1, alignItems: 'center', justifyContent: 'center', paddingTop: 60 },
  emptyChatText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.muted2 },
  emptyChatSub: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginTop: 4 },

  bubbleWrap: { maxWidth: '78%', alignSelf: 'flex-start' },
  bubbleWrapMe: { alignSelf: 'flex-end' },
  bubbleSender: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2, marginBottom: 3, marginLeft: 4 },
  bubble: {
    borderRadius: RADIUS.lg,
    paddingHorizontal: 14,
    paddingVertical: 10,
  },
  bubbleMe: {
    backgroundColor: COLORS.green,
    borderBottomRightRadius: 4,
  },
  bubbleThem: {
    backgroundColor: COLORS.card,
    borderWidth: 1, borderColor: COLORS.border,
    borderBottomLeftRadius: 4,
  },
  bubbleText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.text, lineHeight: 20 },
  bubbleTextMe: { color: COLORS.bg },
  bubbleTime: {
    fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted,
    marginTop: 3, marginLeft: 4,
  },
  bubbleTimeMe: { textAlign: 'right', marginLeft: 0, marginRight: 4 },

  // ── Warning banner ───────────────────────────────────────────────────────────
  warningBanner: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 8,
    backgroundColor: 'rgba(255,152,0,0.12)',
    borderWidth: 1, borderColor: 'rgba(255,152,0,0.3)',
    marginHorizontal: SPACING.xl, borderRadius: RADIUS.md,
    padding: 12, marginBottom: 8,
  },
  warningText: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.orange,
    lineHeight: 18, flex: 1,
  },

  // ── Security note ────────────────────────────────────────────────────────────
  securityNote: {
    paddingHorizontal: SPACING.xl, paddingVertical: 6,
    borderTopWidth: 1, borderTopColor: COLORS.border,
  },
  securityNoteText: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, textAlign: 'center' },

  // ── Input ────────────────────────────────────────────────────────────────────
  inputRow: {
    flexDirection: 'row', alignItems: 'flex-end', gap: 10,
    paddingHorizontal: SPACING.xl, paddingVertical: 12,
    borderTopWidth: 1, borderTopColor: COLORS.border,
    backgroundColor: COLORS.bg,
  },
  input: {
    flex: 1,
    backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 10,
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.text,
    maxHeight: 100,
  },
  sendBtn: {
    width: 44, height: 44,
    borderRadius: 22,
    backgroundColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center',
  },
  sendBtnDisabled: { backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border },
});
