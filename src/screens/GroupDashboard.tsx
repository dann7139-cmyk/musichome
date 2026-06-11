import React from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { COLORS } from '../config/theme';

export default function GroupDashboard() {
  return (
    <View style={styles.container}>
      <Text style={styles.title}>Panel Grupo</Text>
      <Text style={styles.item}>• Ver reservas</Text>
      <Text style={styles.item}>• Editar perfil</Text>
      <Text style={styles.item}>• Subir video</Text>
      <Text style={styles.item}>• Ver estadísticas</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: COLORS.background,
    padding: 24,
  },
  title: {
    fontSize: 24,
    fontWeight: 'bold',
    color: COLORS.primary,
    marginBottom: 20,
  },
  item: {
    color: COLORS.textSecondary,
    marginBottom: 8,
  },
});
