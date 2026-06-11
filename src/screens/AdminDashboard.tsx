import React from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { COLORS } from '../config/theme';

export default function AdminDashboard() {
  return (
    <View style={styles.container}>
      <Text style={styles.title}>Panel Admin</Text>
      <Text style={styles.subtitle}>Aquí verás:</Text>
      <Text style={styles.item}>• Todos los grupos</Text>
      <Text style={styles.item}>• Todas las reservas</Text>
      <Text style={styles.item}>• Ingresos</Text>
      <Text style={styles.item}>• Comisión editable</Text>
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
  subtitle: {
    color: COLORS.text,
    marginBottom: 10,
  },
  item: {
    color: COLORS.textSecondary,
    marginBottom: 6,
  },
});
