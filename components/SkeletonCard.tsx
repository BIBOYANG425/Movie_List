import React from "react";

type SkeletonVariant = "feed" | "journal" | "suggestion";

interface SkeletonCardProps {
  variant: SkeletonVariant;
}

const Shimmer = ({ className }: { className?: string }) => (
  <div className={`animate-pulse bg-zinc-800 rounded ${className ?? ""}`} />
);

function FeedSkeleton() {
  return (
    <div className="flex items-start gap-3 rounded-xl bg-zinc-900 p-4">
      <Shimmer className="h-16 w-16 shrink-0 rounded-lg" />
      <div className="flex flex-1 flex-col gap-2">
        <Shimmer className="h-4 w-3/4 rounded" />
        <Shimmer className="h-3 w-1/2 rounded" />
        <div className="mt-2 flex gap-2">
          <Shimmer className="h-6 w-10 rounded-full" />
          <Shimmer className="h-6 w-10 rounded-full" />
          <Shimmer className="h-6 w-10 rounded-full" />
        </div>
      </div>
    </div>
  );
}

function JournalSkeleton() {
  return (
    <div className="flex items-start gap-3 rounded-xl bg-zinc-900 p-4">
      <Shimmer className="h-16 w-16 shrink-0 rounded-lg" />
      <div className="flex flex-1 flex-col gap-2">
        <Shimmer className="h-4 w-2/3 rounded" />
        <Shimmer className="h-3 w-full rounded" />
        <Shimmer className="h-3 w-full rounded" />
        <Shimmer className="h-3 w-4/5 rounded" />
        <div className="mt-1 flex gap-2">
          <Shimmer className="h-5 w-14 rounded-full" />
          <Shimmer className="h-5 w-16 rounded-full" />
          <Shimmer className="h-5 w-12 rounded-full" />
        </div>
      </div>
    </div>
  );
}

function SuggestionSkeleton() {
  return (
    <div className="flex flex-col gap-2 rounded-xl bg-zinc-900 p-3">
      <Shimmer className="aspect-[2/3] w-full rounded-lg" />
      <Shimmer className="h-4 w-3/4 rounded" />
    </div>
  );
}

const variantMap: Record<SkeletonVariant, React.FC> = {
  feed: FeedSkeleton,
  journal: JournalSkeleton,
  suggestion: SuggestionSkeleton,
};

export function SkeletonCard({ variant }: SkeletonCardProps) {
  const Component = variantMap[variant];
  return <Component />;
}

interface SkeletonListProps {
  count: number;
  variant: SkeletonVariant;
}

export function SkeletonList({ count, variant }: SkeletonListProps) {
  return (
    <>
      {Array.from({ length: count }, (_, i) => (
        <SkeletonCard key={i} variant={variant} />
      ))}
    </>
  );
}

export default SkeletonCard;
