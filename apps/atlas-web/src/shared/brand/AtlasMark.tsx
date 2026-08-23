export function AtlasMark({ compact = false }: { compact?: boolean }) {
  return (
    <div className="flex items-center gap-3" aria-label="Atlas">
      <div className="relative grid size-10 shrink-0 place-items-center overflow-hidden rounded-2xl bg-[linear-gradient(145deg,#6d7cff,#3154f5)] shadow-[0_12px_35px_rgba(67,91,255,0.35)]">
        <span className="absolute inset-[1px] rounded-[15px] border border-white/20" />
        <svg viewBox="0 0 32 32" className="size-6 text-white" aria-hidden="true">
          <path
            d="M16 4 27 26h-5.1l-2.15-4.7h-7.6L10 26H5L16 4Zm0 8.2-2.25 5h4.5l-2.25-5Z"
            fill="currentColor"
          />
        </svg>
      </div>
      {!compact && (
        <div>
          <p className="text-[17px] font-semibold leading-none tracking-[-0.03em] text-white">
            Atlas
          </p>
          <p className="mt-1 text-[10px] font-medium uppercase tracking-[0.22em] text-slate-500">
            Intelligence OS
          </p>
        </div>
      )}
    </div>
  )
}
