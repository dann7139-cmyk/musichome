import { LinearGradient } from 'expo-linear-gradient';
import { ChevronRight, MapPin, Star } from 'lucide-react-native';
import React, { useEffect, useRef, useState } from 'react';
import {
  Animated,
  Dimensions,
  Image,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../config/supabase';
import { COLORS } from '../config/theme';
const CARD_WIDTH = Dimensions.get('window').width - 48;

export default function HomeScreen({ navigation }: any) {
  const [groups, setGroups] = useState<any[]>([]);
  const headerAnim = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    fetchGroups();

    Animated.timing(headerAnim, {
      toValue: 1,
      duration: 600,
      useNativeDriver: true,
    }).start();
  }, []);

  const fetchGroups = async () => {
    const { data } = await supabase.from('groups').select('*');
    if (data) setGroups(data);
  };

  return (
    <View style={styles.container}>
      <SafeAreaView style={styles.safeArea}>
        <Animated.View style={[styles.header, { opacity: headerAnim }]}>
          <View>
            <Text style={styles.welcomeText}>Grupos Disponibles</Text>
          </View>
        </Animated.View>

        <ScrollView
          contentContainerStyle={styles.scrollContent}
          showsVerticalScrollIndicator={false}
        >
          {groups.map((group, index) => (
            <AnimatedCard
              key={group.id}
              group={group}
              index={index}
              navigation={navigation}
            />
          ))}
        </ScrollView>
      </SafeAreaView>
    </View>
  );
}

function AnimatedCard({ group, index, navigation }: any) {
  const slideAnim = useRef(new Animated.Value(50)).current;
  const fadeAnim = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    Animated.parallel([
      Animated.timing(slideAnim, {
        toValue: 0,
        duration: 500,
        delay: index * 120,
        useNativeDriver: true,
      }),
      Animated.timing(fadeAnim, {
        toValue: 1,
        duration: 500,
        delay: index * 120,
        useNativeDriver: true,
      }),
    ]).start();
  }, []);

  return (
    <Animated.View
      style={[
        styles.cardContainer,
        { opacity: fadeAnim, transform: [{ translateY: slideAnim }] },
      ]}
    >
      <Pressable
        style={styles.card}
        onPress={() =>
          navigation.navigate('GroupDetail', { group })
        }
      >
        <Image
          source={{ uri: group.profile_image }}
          style={styles.cardImage}
        />

        <LinearGradient
          colors={['transparent', 'rgba(0,0,0,0.9)']}
          style={styles.cardGradient}
        />

        <View style={styles.cardContent}>
          <Text style={styles.genre}>{group.genre}</Text>
          <Text style={styles.cardTitle}>{group.name}</Text>

          <View style={styles.cardInfo}>
            <View style={styles.infoItem}>
              <MapPin size={14} color={COLORS.textSecondary} />
              <Text style={styles.infoText}>{group.city}</Text>
            </View>

            <View style={styles.infoItem}>
              <Star size={14} color={COLORS.warning} />
              <Text style={styles.infoText}>4.8</Text>
            </View>
          </View>

          <Text style={styles.price}>
            Desde ${group.price_from}
          </Text>
        </View>

        <View style={styles.arrow}>
          <ChevronRight size={24} color={COLORS.primary} />
        </View>
      </Pressable>
    </Animated.View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: COLORS.background,
  },
  safeArea: {
    flex: 1,
  },
  header: {
    paddingHorizontal: 24,
    paddingVertical: 16,
  },
  welcomeText: {
    fontSize: 22,
    fontWeight: '600',
    color: COLORS.text,
  },
  scrollContent: {
    paddingHorizontal: 24,
  },
  cardContainer: {
    marginBottom: 20,
  },
  card: {
    width: CARD_WIDTH,
    height: 220,
    borderRadius: 20,
    overflow: 'hidden',
    backgroundColor: COLORS.card,
  },
  cardImage: {
    width: '100%',
    height: '100%',
    position: 'absolute',
  },
  cardGradient: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    height: '70%',
  },
  cardContent: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0,
    padding: 20,
  },
  genre: {
    color: COLORS.primary,
    fontSize: 12,
    marginBottom: 4,
  },
  cardTitle: {
    fontSize: 22,
    fontWeight: '700',
    color: COLORS.text,
    marginBottom: 6,
  },
  cardInfo: {
    flexDirection: 'row',
    gap: 16,
    marginBottom: 4,
  },
  infoItem: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
  },
  infoText: {
    fontSize: 14,
    color: COLORS.textSecondary,
  },
  price: {
    fontSize: 12,
    color: COLORS.textMuted,
  },
  arrow: {
    position: 'absolute',
    right: 16,
    top: '50%',
    marginTop: -12,
    width: 40,
    height: 40,
    borderRadius: 20,
    backgroundColor: COLORS.primaryMuted,
    justifyContent: 'center',
    alignItems: 'center',
  },
});
