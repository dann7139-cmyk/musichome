import React, { createContext, useContext, useState } from 'react';

type GroupBadgesCtx = {
  pendingQuotesCount: number;
  setPendingQuotesCount: (n: number) => void;
};

const GroupBadgesContext = createContext<GroupBadgesCtx>({
  pendingQuotesCount: 0,
  setPendingQuotesCount: () => {},
});

export const GroupBadgesProvider = ({ children }: { children: React.ReactNode }) => {
  const [pendingQuotesCount, setPendingQuotesCount] = useState(0);
  return (
    <GroupBadgesContext.Provider value={{ pendingQuotesCount, setPendingQuotesCount }}>
      {children}
    </GroupBadgesContext.Provider>
  );
};

export const useGroupBadges = () => useContext(GroupBadgesContext);
