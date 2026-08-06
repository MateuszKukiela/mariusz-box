# Reconcile pending transactions after every Enable Banking sync.
#
# Sure pairs a pending transaction with its booked counterpart via
# Entry.reconcile_pending_duplicates, and drops authorisations that never
# booked via Entry.auto_exclude_stale_pending. Both are only ever called from
# the SimpleFIN importer, so Enable Banking connections fetch pending rows and
# then leave them unreconciled forever, double-counting the spend.
#
# EnableBankingItem::Syncer#perform_post_sync is an empty hook, so fill it.
# Delete this file and its compose mount once upstream calls the two methods
# from the shared sync path.

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