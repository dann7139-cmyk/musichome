import { analyzeMessage } from './phoneFilter';

const EXTRA_PATTERNS: RegExp[] = [
  /disc[o0]rd/i,
  /text\s+me/i,
  /m[i1]\s+n[úu]m[e3]ro/i,
  /https?:\/\//i,
];

export function containsBlockedContact(text: string): boolean {
  if (!text.trim()) return false;
  if (analyzeMessage(text).blocked) return true;
  return EXTRA_PATTERNS.some(re => re.test(text));
}
