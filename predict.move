module predict_market::prediction {
    use std::signer;
    use std::error;
    use std::vector;
    use aptos_std::table::{Self, Table};
    use std::timestamp;
    use supra_framework::coin::{Self, Coin, CoinStore};
    use std::string::{Self, String};
    use supra_framework::supra_coin::SupraCoin;

    const MODULE_ADDRESS: address = @predict_market;

    // --- Errors ---
    const ERROR_SLOT_ID_NOT_PRESENT: u64 = 1;
    const ERROR_NO_PREDICTION_FOUND: u64 = 2;
    const ERROR_NOT_AUTH: u64 = 5;
    const ERROR_ALREADY_PRESENT_IN_SLOT: u64 = 6;
    const ERROR_CONTRACT_NOT_INITIALISED: u64 = 9;
    const ERROR_CANNOT_PREDICT_AFTER_INTERVAL: u64 = 11;
    const ERROR_START_TIME_SHOULD_BE_GREATER_THAN_END_TIME: u64 = 10;
    const ERROR_SLOT_NOT_RESOLVED: u64 = 8;
    const ERROR_SLOT_IS_ALREADY_RESOLVED: u64 = 12;
    const ERROR_PREDICTION_NOT_A_WINNER: u64 = 13;
    const ERROR_REWARD_ALREADY_CLAIMED: u64 = 14;
    const ERROR_NO_WINNERS_IN_POOL: u64 = 15;

    // --- Data Structures ---

    struct UserSlotKey has copy, drop, store {
        user_address: address,
        slot_id: u256,
    }

    struct GlobalVars has key, store {
        auth_cum_lock: address,
        supra_coin_vault: Coin<SupraCoin>, // Changed from CoinStore to Coin
        prediction_data: Table<UserSlotKey, PredictionInfo>,
        slot_to_user_addresses: Table<u256, vector<address>>,
        slot_id_to_slot_details: Table<u256, SlotDetails>,
    }

    struct SlotDetails has key, store, copy, drop {
        slot_id: u256,
        start_time: u64,
        end_time: u64,
        start_price: String,
        options: vector<String>,
        winning_option: u64,
        total_pool: u64,
        winners_pool: u64,
    }

    struct PredictionInfo has key, store, drop, copy {
        coins: u64,
        option_nos: u64,
        claimed: bool,
    }

    // --- Public Functions ---

    fun init_module(auth_cum_lock: &signer) {
        move_to(auth_cum_lock, GlobalVars {
            auth_cum_lock: signer::address_of(auth_cum_lock),
            supra_coin_vault: coin::zero<SupraCoin>(), // Initialized with zero
            prediction_data: table::new<UserSlotKey, PredictionInfo>(),
            slot_to_user_addresses: table::new<u256, vector<address>>(),
            slot_id_to_slot_details: table::new<u256, SlotDetails>(),
        });
    }

    public entry fun create_slot(account: &signer, slot_id: u256, start_time: u64, end_time: u64, start_price: String, options: vector<String>) acquires GlobalVars {
        let global_vars = borrow_global_mut<GlobalVars>(signer::address_of(account));
        assert!(global_vars.auth_cum_lock == signer::address_of(account), error::permission_denied(ERROR_NOT_AUTH));
        assert!(end_time > start_time, error::aborted(ERROR_START_TIME_SHOULD_BE_GREATER_THAN_END_TIME));

        let slot_struct = SlotDetails {
            slot_id,
            start_time,
            end_time,
            start_price,
            options,
            winning_option: 18446744073709551615, // u64::MAX, indicates "not resolved"
            total_pool: 0,
            winners_pool: 0,
        };
        table::add(&mut global_vars.slot_id_to_slot_details, slot_id, slot_struct);
    }

    public entry fun create_prediction(account: &signer, slot_id: u256, coins_to_bet: u64, option_nos: u64) acquires GlobalVars {
        let admin_address = borrow_global<GlobalVars>(MODULE_ADDRESS).auth_cum_lock;
        let global_vars = borrow_global_mut<GlobalVars>(admin_address);
        let account_addr = signer::address_of(account);

        let key = UserSlotKey { user_address: account_addr, slot_id: slot_id };
        
        assert!(!table::contains(&global_vars.prediction_data, key), error::already_exists(ERROR_ALREADY_PRESENT_IN_SLOT));
        
        let slot_details = table::borrow_mut(&mut global_vars.slot_id_to_slot_details, slot_id);
        assert!(slot_details.end_time > timestamp::now_seconds(), error::aborted(ERROR_CANNOT_PREDICT_AFTER_INTERVAL));

        let coins_bet_obj = coin::withdraw<SupraCoin>(account, coins_to_bet);
        coin::merge(&mut global_vars.supra_coin_vault, coins_bet_obj); // Merge coins into the vault

        slot_details.total_pool = slot_details.total_pool + coins_to_bet;

        let pred = PredictionInfo {
            coins: coins_to_bet,
            option_nos,
            claimed: false,
        };
        table::add(&mut global_vars.prediction_data, key, pred);

        if (!table::contains(&global_vars.slot_to_user_addresses, slot_id)) {
            let participants = vector::empty<address>();
            vector::push_back(&mut participants, account_addr);
            table::add(&mut global_vars.slot_to_user_addresses, slot_id, participants);
        } else {
            let participants = table::borrow_mut(&mut global_vars.slot_to_user_addresses, slot_id);
            vector::push_back(participants, account_addr);
        }
    }

    public entry fun update_final_price(account: &signer, slot_id: u256, winning_option_no: u64) acquires GlobalVars {
        let global_vars = borrow_global_mut<GlobalVars>(signer::address_of(account));
        assert!(global_vars.auth_cum_lock == signer::address_of(account), error::permission_denied(ERROR_NOT_AUTH));

        let slot_details = table::borrow_mut(&mut global_vars.slot_id_to_slot_details, slot_id);
        assert!(slot_details.winning_option == 18446744073709551615, error::aborted(ERROR_SLOT_IS_ALREADY_RESOLVED));

        slot_details.winning_option = winning_option_no;

        let winners_total_stake = 0;
        if (table::contains(&global_vars.slot_to_user_addresses, slot_id)) {
            let participants = table::borrow(&global_vars.slot_to_user_addresses, slot_id);
            let i = 0;
            while (i < vector::length(participants)) {
                let participant_addr = *vector::borrow(participants, i);
                let key = UserSlotKey { user_address: participant_addr, slot_id: slot_id };
                let prediction = table::borrow(&global_vars.prediction_data, key);

                if (prediction.option_nos == winning_option_no) {
                    winners_total_stake = winners_total_stake + prediction.coins;
                };
                i = i + 1;
            };
        };
        slot_details.winners_pool = winners_total_stake;
    }

    public entry fun claim_reward(account: &signer, slot_id: u256) acquires GlobalVars {
        let admin_address = borrow_global<GlobalVars>(MODULE_ADDRESS).auth_cum_lock;
        let global_vars = borrow_global_mut<GlobalVars>(admin_address);
        let user_addr = signer::address_of(account);

        let slot_details = table::borrow(&global_vars.slot_id_to_slot_details, slot_id);

        assert!(slot_details.winning_option != 18446744073709551615, error::aborted(ERROR_SLOT_NOT_RESOLVED));
        assert!(slot_details.winners_pool > 0, error::aborted(ERROR_NO_WINNERS_IN_POOL));

        let key = UserSlotKey { user_address: user_addr, slot_id: slot_id };
        assert!(table::contains(&global_vars.prediction_data, key), error::not_found(ERROR_NO_PREDICTION_FOUND));
        
        let prediction = table::borrow_mut(&mut global_vars.prediction_data, key);

        assert!(!prediction.claimed, error::aborted(ERROR_REWARD_ALREADY_CLAIMED));
        assert!(prediction.option_nos == slot_details.winning_option, error::aborted(ERROR_PREDICTION_NOT_A_WINNER));

        // Proportional reward calculation with casting to u128 to prevent overflow
        let reward_amount = ((((prediction.coins as u128) * (slot_details.total_pool as u128)) / (slot_details.winners_pool as u128)) as u64);

        // Extract coins from the vault and deposit to the user
        let reward_coins = coin::extract(&mut global_vars.supra_coin_vault, reward_amount);
        coin::deposit<SupraCoin>(user_addr, reward_coins);

        prediction.claimed = true;
    }

    // --- View Functions ---

    #[view]
    public fun get_prediction(user: address, slot_id: u256): PredictionInfo acquires GlobalVars {
        let admin_address = borrow_global<GlobalVars>(MODULE_ADDRESS).auth_cum_lock;
        let global_vars = borrow_global<GlobalVars>(admin_address);
        let key = UserSlotKey { user_address: user, slot_id: slot_id };
        assert!(table::contains(&global_vars.prediction_data, key), error::not_found(ERROR_NO_PREDICTION_FOUND));
        *table::borrow(&global_vars.prediction_data, key)
    }

    #[view]
    public fun get_slot_details(slot_id: u256): SlotDetails acquires GlobalVars {
        let admin_address = borrow_global<GlobalVars>(MODULE_ADDRESS).auth_cum_lock;
        let global_vars = borrow_global<GlobalVars>(admin_address);
        assert!(table::contains(&global_vars.slot_id_to_slot_details, slot_id), error::not_found(ERROR_SLOT_ID_NOT_PRESENT));
        *table::borrow(&global_vars.slot_id_to_slot_details, slot_id)
    }
}
