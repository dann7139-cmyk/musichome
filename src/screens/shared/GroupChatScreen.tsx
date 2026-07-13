/**
 * GroupChatScreen — chats INTERNOS del grupo (tabla direct_messages, sql/481).
 *
 *   mode 'dm'      → 1:1 dueño ↔ talento (invitado de tocada o integrante).
 *                    Si no llega peerId, se resuelve al dueño del grupo
 *                    (lado talento: "Chat con el grupo").
 *   mode 'general' → chat grupal (dueño + integrantes fijos).
 *
 * A diferencia del chat de evento (cliente↔grupo): NO es efímero, y SÍ se
 * permiten fotos, videos y números — es coordinación interna del grupo.
 * La notificación del mensaje la inserta un TRIGGER en el servidor.
 */
import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator, FlatList, Image, KeyboardAvoidingView, Platform,
  Pressable, StyleSheet, Text, TextInput, View, Alert,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ArrowLeft, Camera, Send } from 'lucide-react-native';
import * as ImagePicker from 'expo-image-picker';
import * as ImageManipulator from 'expo-image-manipulator';
import * as WebBrowser from 'expo-web-browser';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

interface DM {
  id: string;
  group_id: string;
  sender_id: string;
  recipient_id: string | null;
  content: string | null;
  attachment_path: string | null;
  attachment_type: 'image' | 'video' | null;
  created_at: string;
}

export default function GroupChatScreen({ route, navigation }: any) {
  const { groupId, mode = 'dm', peerId: peerIdParam } = route.params as {
    groupId: string; mode?: 'dm' | 'general'; peerId?: string;
  };

  const [meId, setMeId]         = useState<string | null>(null);
  const [group, setGroup]       = useState<{ name: string; profile_image: string | null; owner_id: string } | null>(null);
  const [peer, setPeer]         = useState<{ id: string; full_name: string | null; avatar_url: string | null } | null>(null);
  const [senderNames, setSenderNames] = useState<Record<string, { name: string; avatar: string | null }>>({});
  const [messages, setMessages] = useState<DM[]>([]);
  const [text, setText]         = useState('');
  const [sending, setSending]   = useState(false);
  const [uploading, setUploading] = useState(false);
  const [loading, setLoading]   = useState(true);
  const [signedUrls, setSignedUrls] = useState<Record<string, string>>({});
  const listRef = useRef<FlatList>(null);
  const peerIdRef = useRef<string | null>(peerIdParam ?? null);

  const signAttachment = useCallback(async (path: string) => {
    const { data } = await supabase.storage.from('chat-media').createSignedUrl(path, 3600);
    if (data?.signedUrl) setSignedUrls(prev => ({ ...prev, [path]: data.signedUrl }));
  }, []);

  // ── Carga inicial: yo, grupo, peer y mensajes ────────────────────────────
  useEffect(() => {
    (async () => {
      const { data: u } = await supabase.auth.getUser();
      if (!u.user) return;
      setMeId(u.user.id);

      const { data: g } = await supabase
        .from('groups').select('name, profile_image, owner_id').eq('id', groupId).single();
      if (!g) { setLoading(false); return; }
      setGroup(g);

      let pid = peerIdParam ?? null;
      if (mode === 'dm' && !pid) pid = g.owner_id;      // lado talento: chat con el dueño
      peerIdRef.current = pid;

      if (mode === 'dm' && pid) {
        const { data: p } = await supabase
          .from('profiles').select('id, full_name, avatar_url').eq('id', pid).single();
        if (p) setPeer(p);
      }

      // Mensajes de ESTA conversación
      let q = supabase.from('direct_messages').select('*').eq('group_id', groupId)
        .order('created_at', { ascending: true }).limit(200);
      if (mode === 'general') {
        q = q.is('recipient_id', null);
      } else if (pid) {
        q = q.or(
          `and(sender_id.eq.${u.user.id},recipient_id.eq.${pid}),and(sender_id.eq.${pid},recipient_id.eq.${u.user.id})`,
        );
      }
      const { data: msgs } = await q;
      const list = (msgs ?? []) as DM[];
      setMessages(list);
      list.forEach(m => { if (m.attachment_path) void signAttachment(m.attachment_path); });

      // Nombres de emisores (para el chat grupal)
      if (mode === 'general') {
        const ids = [...new Set(list.map(m => m.sender_id))];
        if (ids.length > 0) {
          const { data: profs } = await supabase
            .from('profiles').select('id, full_name, avatar_url').in('id', ids);
          const map: Record<string, { name: string; avatar: string | null }> = {};
          (profs ?? []).forEach((p: any) => { map[p.id] = { name: p.full_name ?? 'Integrante', avatar: p.avatar_url }; });
          setSenderNames(map);
        }
      }
      setLoading(false);
    })();
  }, [groupId, mode, peerIdParam, signAttachment]);

  // ── Realtime: mensajes nuevos de esta conversación ───────────────────────
  useEffect(() => {
    if (!meId) return;
    const ch = supabase
      .channel(`dm-${groupId}-${mode}-${peerIdRef.current ?? 'all'}`)
      .on('postgres_changes', {
        event: 'INSERT', schema: 'public', table: 'direct_messages',
        filter: `group_id=eq.${groupId}`,
      }, (payload) => {
        const m = payload.new as DM;
        const pid = peerIdRef.current;
        const belongs = mode === 'general'
          ? m.recipient_id === null
          : (m.sender_id === meId && m.recipient_id === pid) ||
            (m.sender_id === pid && m.recipient_id === meId);
        if (!belongs) return;
        setMessages(prev => prev.some(x => x.id === m.id) ? prev : [...prev, m]);
        if (m.attachment_path) void signAttachment(m.attachment_path);
        if (mode === 'general' && !senderNames[m.sender_id]) {
          supabase.from('profiles').select('id, full_name, avatar_url').eq('id', m.sender_id).single()
            .then(({ data: p }) => {
              if (p) setSenderNames(prev => ({ ...prev, [p.id]: { name: p.full_name ?? 'Integrante', avatar: p.avatar_url } }));
            });
        }
        setTimeout(() => listRef.current?.scrollToEnd({ animated: true }), 80);
      })
      .subscribe();
    return () => { supabase.removeChannel(ch); };
  }, [groupId, mode, meId, signAttachment, senderNames]);

  // ── Enviar texto (SIN moderación — chat interno del grupo) ───────────────
  const handleSend = async () => {
    const t = text.trim();
    if (!t || !meId || sending) return;
    setSending(true);
    setText('');
    const { error } = await supabase.from('direct_messages').insert({
      group_id: groupId,
      sender_id: meId,
      recipient_id: mode === 'general' ? null : peerIdRef.current,
      content: t,
    });
    setSending(false);
    if (error) { setText(t); Alert.alert('Error', 'No se pudo enviar. Intenta de nuevo.'); }
  };

  // ── Enviar foto o video ──────────────────────────────────────────────────
  const handleAttach = async () => {
    if (uploading || !meId) return;
    const res = await ImagePicker.launchImageLibraryAsync({
      mediaTypes: ImagePicker.MediaTypeOptions.All,
      quality: 0.8,
      videoMaxDuration: 60,
    });
    if (res.canceled || !res.assets?.[0]) return;
    const asset = res.assets[0];
    setUploading(true);
    try {
      let uri = asset.uri;
      let ext = 'jpg';
      let contentType = 'image/jpeg';
      const isVideo = asset.type === 'video';
      if (isVideo) {
        ext = 'mp4';
        contentType = 'video/mp4';
        if ((asset.fileSize ?? 0) > 50 * 1024 * 1024) {
          Alert.alert('Video muy pesado', 'Máximo 50 MB — intenta con uno más corto.');
          setUploading(false);
          return;
        }
      } else {
        // Comprimir imagen (mismo patrón que comprobantes)
        const manip = await ImageManipulator.manipulateAsync(
          asset.uri, [{ resize: { width: 1440 } }],
          { compress: 0.75, format: ImageManipulator.SaveFormat.JPEG },
        );
        uri = manip.uri;
      }
      const path = `${groupId}/${meId}_${Date.now()}.${ext}`;
      const buf = await fetch(uri).then(r => r.arrayBuffer());
      const { error: upErr } = await supabase.storage.from('chat-media')
        .upload(path, buf, { contentType });
      if (upErr) throw upErr;

      const { error } = await supabase.from('direct_messages').insert({
        group_id: groupId,
        sender_id: meId,
        recipient_id: mode === 'general' ? null : peerIdRef.current,
        attachment_path: path,
        attachment_type: isVideo ? 'video' : 'image',
      });
      if (error) throw error;
    } catch {
      Alert.alert('Error', 'No se pudo enviar el archivo. Intenta de nuevo.');
    }
    setUploading(false);
  };

  // ── Ver perfil del talento (solo el dueño en 1:1) ────────────────────────
  const amOwner = !!group && !!meId && group.owner_id === meId;
  const openPeerProfile = async () => {
    if (!peer) return;
    const { data: jb } = await supabase
      .from('job_board_profiles').select('*').eq('user_id', peer.id).maybeSingle();
    navigation.navigate('TalentProfile', {
      talent: { ...(jb ?? {}), user_id: peer.id, full_name: peer.full_name, avatar_url: peer.avatar_url },
      isUsa: false,
      groupId,
      canInvite: false,
    });
  };

  const headerName = mode === 'general'
    ? `Chat de ${group?.name ?? 'tu grupo'}`
    : (peer?.full_name ?? 'Chat');
  const headerAvatar = mode === 'general' ? group?.profile_image : peer?.avatar_url;

  const renderItem = ({ item: m }: { item: DM }) => {
    const mine = m.sender_id === meId;
    const senderInfo = senderNames[m.sender_id];
    const url = m.attachment_path ? signedUrls[m.attachment_path] : null;
    return (
      <View style={[s.bubbleRow, mine ? s.bubbleRowMine : s.bubbleRowTheirs]}>
        <View style={[s.bubble, mine ? s.bubbleMine : s.bubbleTheirs]}>
          {mode === 'general' && !mine && (
            <Text style={s.bubbleSender}>{senderInfo?.name ?? 'Integrante'}</Text>
          )}
          {m.attachment_type === 'image' && (
            url
              ? <Pressable onPress={() => WebBrowser.openBrowserAsync(url)}>
                  <Image source={{ uri: url }} style={s.bubbleImage} />
                </Pressable>
              : <View style={[s.bubbleImage, s.bubbleImageLoading]}><ActivityIndicator color={COLORS.green} /></View>
          )}
          {m.attachment_type === 'video' && (
            <Pressable
              style={s.videoChip}
              onPress={() => url && WebBrowser.openBrowserAsync(url)}
            >
              <Text style={s.videoChipTx}>🎬 Ver video</Text>
            </Pressable>
          )}
          {!!m.content && <Text style={s.bubbleText}>{m.content}</Text>}
          <Text style={s.bubbleTime}>
            {new Date(m.created_at).toLocaleTimeString('es-MX', { hour: '2-digit', minute: '2-digit' })}
          </Text>
        </View>
      </View>
    );
  };

  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={{ flex: 1 }}>
        {/* Header: foto + nombre + ver perfil */}
        <View style={s.header}>
          <Pressable style={s.backBtn} onPress={() => navigation.goBack()} hitSlop={8}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          {headerAvatar
            ? <Image source={{ uri: headerAvatar }} style={s.headerAvatar} />
            : <View style={[s.headerAvatar, s.headerAvatarEmpty]}>
                <Text style={s.headerAvatarTx}>{(headerName ?? '?').charAt(0).toUpperCase()}</Text>
              </View>
          }
          <View style={{ flex: 1 }}>
            <Text style={s.headerTitle} numberOfLines={1}>{headerName}</Text>
            <Text style={s.headerSub}>
              {mode === 'general' ? 'Dueño e integrantes' : group?.name ?? ''}
            </Text>
          </View>
          {mode === 'dm' && amOwner && peer && (
            <Pressable style={s.profileBtn} onPress={openPeerProfile} hitSlop={6}>
              <Text style={s.profileBtnTx}>Ver perfil</Text>
            </Pressable>
          )}
        </View>

        {loading ? (
          <View style={s.center}><ActivityIndicator color={COLORS.green} size="large" /></View>
        ) : (
          <FlatList
            ref={listRef}
            data={messages}
            keyExtractor={m => m.id}
            renderItem={renderItem}
            contentContainerStyle={s.listContent}
            onContentSizeChange={() => listRef.current?.scrollToEnd({ animated: false })}
            ListEmptyComponent={
              <View style={s.emptyWrap}>
                <Text style={s.emptyIcon}>💬</Text>
                <Text style={s.emptyTx}>
                  {mode === 'general'
                    ? 'Aquí platica todo el grupo — fotos, videos y lo que necesiten coordinar.'
                    : 'Coordínense por aquí — pueden compartir fotos, videos y números.'}
                </Text>
              </View>
            }
          />
        )}

        {/* Input */}
        <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
          <View style={s.inputRow}>
            <Pressable style={s.attachBtn} onPress={handleAttach} disabled={uploading}>
              {uploading
                ? <ActivityIndicator color={COLORS.green} size="small" />
                : <Camera size={20} color={COLORS.green} />}
            </Pressable>
            <TextInput
              style={s.input}
              value={text}
              onChangeText={setText}
              placeholder="Escribe un mensaje…"
              placeholderTextColor={COLORS.muted}
              maxLength={1000}
              multiline
            />
            <Pressable
              style={[s.sendBtn, (!text.trim() || sending) && { opacity: 0.4 }]}
              onPress={handleSend}
              disabled={!text.trim() || sending}
            >
              <Send size={18} color="#000" />
            </Pressable>
          </View>
        </KeyboardAvoidingView>
      </SafeAreaView>
    </View>
  );
}

const s = StyleSheet.create({
  root:   { flex: 1, backgroundColor: COLORS.bg },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  header: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    paddingHorizontal: SPACING.lg, paddingVertical: 10,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 38, height: 38, borderRadius: 12, alignItems: 'center', justifyContent: 'center',
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  headerAvatar:      { width: 40, height: 40, borderRadius: 20 },
  headerAvatarEmpty: { backgroundColor: COLORS.card2, alignItems: 'center', justifyContent: 'center', borderWidth: 1, borderColor: COLORS.border },
  headerAvatarTx:    { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.green },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15.5, color: COLORS.text },
  headerSub:   { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted2, marginTop: 1 },
  profileBtn: {
    paddingHorizontal: 12, paddingVertical: 7, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.4)', backgroundColor: 'rgba(0,230,118,0.08)',
  },
  profileBtnTx: { fontFamily: FONTS.bodySemiBold, fontSize: 11.5, color: COLORS.green },

  listContent: { padding: SPACING.lg, gap: 8, flexGrow: 1 },
  emptyWrap: { flex: 1, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 40, gap: 10 },
  emptyIcon: { fontSize: 34 },
  emptyTx:   { fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.muted2, textAlign: 'center', lineHeight: 18 },

  bubbleRow:       { flexDirection: 'row' },
  bubbleRowMine:   { justifyContent: 'flex-end' },
  bubbleRowTheirs: { justifyContent: 'flex-start' },
  bubble: {
    maxWidth: '80%', borderRadius: 16, paddingHorizontal: 12, paddingVertical: 8, gap: 4,
  },
  bubbleMine:   { backgroundColor: 'rgba(0,230,118,0.14)', borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)', borderBottomRightRadius: 4 },
  bubbleTheirs: { backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border, borderBottomLeftRadius: 4 },
  bubbleSender: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green },
  bubbleText:   { fontFamily: FONTS.body, fontSize: 13.5, color: COLORS.text, lineHeight: 19 },
  bubbleTime:   { fontFamily: FONTS.body, fontSize: 9.5, color: COLORS.muted, alignSelf: 'flex-end' },
  bubbleImage:        { width: 200, height: 200, borderRadius: 12, backgroundColor: COLORS.card2 },
  bubbleImageLoading: { alignItems: 'center', justifyContent: 'center' },
  videoChip: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md, borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 10,
  },
  videoChipTx: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },

  inputRow: {
    flexDirection: 'row', alignItems: 'flex-end', gap: 8,
    paddingHorizontal: SPACING.lg, paddingVertical: 10,
    borderTopWidth: 1, borderTopColor: COLORS.border, backgroundColor: COLORS.bg,
  },
  attachBtn: {
    width: 42, height: 42, borderRadius: 21, alignItems: 'center', justifyContent: 'center',
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
  },
  input: {
    flex: 1, minHeight: 42, maxHeight: 110,
    backgroundColor: COLORS.card, borderRadius: 21, borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 10,
    fontFamily: FONTS.body, fontSize: 13.5, color: COLORS.text,
  },
  sendBtn: {
    width: 42, height: 42, borderRadius: 21, alignItems: 'center', justifyContent: 'center',
    backgroundColor: '#FFFFFF',
    shadowColor: '#00E676', shadowOpacity: 0.3, shadowRadius: 8, shadowOffset: { width: 0, height: 2 },
    elevation: 4,
  },
});
