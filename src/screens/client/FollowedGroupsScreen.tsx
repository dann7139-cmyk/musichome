import { ArrowLeft, Music2, Users } from 'lucide-react-native';
import React, { useCallback, useState } from 'react';
import {
  ActivityIndicator,
  FlatList,
  Image,
  Pressable,
  RefreshControl,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useFocusEffect } from '@react-navigation/native';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { useAuth } from '../../context/AuthContext';

export default function FollowedGroupsScreen({ navigation }: any) {
  const { t } = useTranslation();
  const { user } = useAuth();
  const [groups,   setGroups]   = useState<any[]>([]);
  const [loading,  setLoading]  = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  const fetchGroups = useCallback(async () => {
    if (!user) { setLoading(false); return; }
    const { data } = await supabase
      .from('group_follows')
      .select('created_at, groups(id, name, profile_image, genre, city, country, is_verified)')
      .eq('user_id', user.id)
      .order('created_at', { ascending: false });

    setGroups((data ?? []).map((row: any) => row.groups).filter(Boolean));
    setLoading(false);
  }, [user]);

  useFocusEffect(useCallback(() => { fetchGroups(); }, [fetchGroups]));

  const onRefresh = async () => {
    setRefreshing(true);
    await fetchGroups();
    setRefreshing(false);
  };

  return (
    <SafeAreaView style={s.safe} edges={['top']}>
      <View style={s.header}>
        <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color="#fff" />
        </Pressable>
        <Text style={s.headerTitle}>{t('followedGroupsScreen.headerTitle')}</Text>
        <View style={{ width: 36 }} />
      </View>

      {loading ? (
        <View style={s.center}><ActivityIndicator color={COLORS.green} /></View>
      ) : groups.length === 0 ? (
        <View style={s.center}>
          <Users size={40} color={COLORS.muted} />
          <Text style={s.emptyTitle}>{t('followedGroupsScreen.emptyTitle')}</Text>
          <Text style={s.emptyText}>{t('followedGroupsScreen.emptyText')}</Text>
        </View>
      ) : (
        <FlatList
          data={groups}
          keyExtractor={item => item.id}
          contentContainerStyle={{ padding: SPACING.xl, gap: 10 }}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
          renderItem={({ item }) => (
            <Pressable style={s.card} onPress={() => navigation.navigate('GroupDetail', { group: item })}>
              {item.profile_image ? (
                <Image source={{ uri: item.profile_image }} style={s.avatar} />
              ) : (
                <View style={[s.avatar, s.avatarPh]}>
                  <Music2 size={20} color={COLORS.muted} />
                </View>
              )}
              <View style={{ flex: 1 }}>
                <Text style={s.cardName} numberOfLines={1}>{item.name}</Text>
                <Text style={s.cardMeta} numberOfLines={1}>
                  {[item.genre, [item.city, item.country].filter(Boolean).join(', ')].filter(Boolean).join(' · ')}
                </Text>
              </View>
            </Pressable>
          )}
        />
      )}
    </SafeAreaView>
  );
}

const s = StyleSheet.create({
  safe: { flex: 1, backgroundColor: COLORS.bg },
  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingVertical: 14,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 36, height: 36, borderRadius: 18, alignItems: 'center', justifyContent: 'center',
    backgroundColor: COLORS.card2,
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: '#fff' },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 10, paddingHorizontal: 40 },
  emptyTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: '#fff', textAlign: 'center' },
  emptyText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted, textAlign: 'center' },
  card: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 12,
  },
  avatar: { width: 48, height: 48, borderRadius: 24, backgroundColor: COLORS.card2 },
  avatarPh: { alignItems: 'center', justifyContent: 'center' },
  cardName: { fontFamily: FONTS.bodySemiBold, fontSize: 14.5, color: '#fff' },
  cardMeta: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginTop: 2 },
});
