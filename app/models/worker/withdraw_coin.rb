module Worker
  class WithdrawCoin

    def process(payload, metadata, delivery_info)
      payload.symbolize_keys!

      Withdraw.transaction do
        withdraw = Withdraw.lock.find payload[:id]

        return unless withdraw.processing?

        withdraw.whodunnit('Worker::WithdrawCoin') do
          withdraw.call_rpc
          withdraw.save!
        end
      end

      Withdraw.transaction do
        withdraw = Withdraw.lock.find payload[:id]
	      c = Currency.find_by_code(withdraw.currency.to_s)
        return unless withdraw.almost_done?
        if withdraw.currency == 'eth'
          balance = Web3T.get_balance(c.main_address)
          raise Account::BalanceError, 'Insufficient coins' if balance < withdraw.sum
          fee = [withdraw.fee.to_f || withdraw.channel.try(:fee) || 0.0005, 0.1].min
          txid = Web3T.send_eth(c.main_privatekey, withdraw.fund_uid, withdraw.amount.to_f)
        else
          balance = CoinRPC[withdraw.currency].getbalance.to_d
          raise Account::BalanceError, 'Insufficient coins' if balance < withdraw.sum

          fee = [withdraw.fee.to_f || withdraw.channel.try(:fee) || 0.0005, 0.1].min

          CoinRPC[withdraw.currency].settxfee fee
          txid = CoinRPC[withdraw.currency].sendtoaddress withdraw.fund_uid, withdraw.amount.to_f

        end
        withdraw.whodunnit('Worker::WithdrawCoin') do
          withdraw.update_column :txid, txid

          # withdraw.succeed! will start another transaction, cause
          # Account after_commit callbacks not to fire
          withdraw.succeed
          withdraw.save!
        end
      end
    end

  end
end
