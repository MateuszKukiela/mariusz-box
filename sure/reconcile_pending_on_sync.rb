# Fallback reconciliation of pending transactions, for banks whose settlement
# breaks Enable Banking's ID matching.
#
# The importer already retires settled pending rows ("C4"), matching on the
# provider fingerprint or a shared entry_reference. That is exact and is the
# right mechanism where it works — do not replace it.
#
# mBank defeats both strategies: the authorisation and the posting carry
# different references (P02000002846... vs 20260805...), and no entry_reference
# is retained, so the two rows share no identifier. The pair then lingers and
# the spend is counted twice.
#
# Entry.reconcile_pending_duplicates is the heuristic fallback for exactly this
# situation (name + amount + date window), but it is only wired into the
# SimpleFIN importer. EnableBankingItem::Syncer#perform_post_sync is an empty
# hook, so run it there, after C4 has already removed everything it could match
# properly. Entry.auto_exclude_stale_pending drops authorisations that never
# booked at all.
#
# Delete this once mBank keeps a stable reference across settlement, or once
# upstream wires the fallback into the shared sync path.

Rails.application.config.to_prepare do
  module ReconcilePendingOnSync
    def perform_post_sync
      super

      enable_banking_item.accounts.each do |account|
        stats = Entry.reconcile_pending_duplicates(account: account)
        excluded = Entry.auto_exclude_stale_pending(account: account)
        Rails.logger.info(
          "[reconcile-on-sync] account=#{account.id} " \
          "checked=#{stats[:checked]} reconciled=#{stats[:reconciled]} stale_excluded=#{excluded}"
        )
      end
    rescue => e
      # Never let reconciliation break a sync that otherwise succeeded.
      Rails.logger.error("[reconcile-on-sync] failed: #{e.class}: #{e.message}")
    end
  end

  EnableBankingItem::Syncer.prepend(ReconcilePendingOnSync)
end