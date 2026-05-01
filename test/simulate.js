#!/usr/bin/env node
// Simulates a Balatro run and writes seed_SIMULATE_1.jsonl + .txt
// to ~/balatro-logs/ — lets you test the HTML viewer without the game.

const fs = require('fs');
const path = require('path');
const os = require('os');

const LOG_DIR = path.join(os.homedir(), 'balatro-logs');
fs.mkdirSync(LOG_DIR, { recursive: true });

const SEED = 'SIMULATE';
const BASE = path.join(LOG_DIR, `seed_${SEED}_1`);
const jsonlFd = fs.openSync(BASE + '.jsonl', 'w');
const txtFd   = fs.openSync(BASE + '.txt',   'w');

let seq = 0;

function emit(event, data) {
    seq++;
    const entry = { seq, ts: Math.floor(Date.now() / 1000), event, ...data };
    fs.writeSync(jsonlFd, JSON.stringify(entry) + '\n');
    const ts = new Date().toTimeString().slice(0, 8);
    let summary = `[${ts}] ${event}`;
    if (data.action?.cards)     summary += ' [' + data.action.cards.map(c => c.value?.[0] + c.suit?.[0]).join(' ') + ']';
    if (data.action?.item_key)  summary += ' ' + data.action.item_key;
    if (data.resolution?.hand_type) summary += ' → ' + data.resolution.hand_type;
    if (data.resolution?.score) summary += '  score=' + data.resolution.score;
    if (data.resolution?.final_score) summary += '  total=' + data.resolution.final_score;
    if (data.action?.delta != null) summary += (data.action.delta >= 0 ? ' +' : ' ') + data.action.delta + '$';
    fs.writeSync(txtFd, summary + '\n');
}

// ── helpers ──────────────────────────────────────────────────

function card(suit, value, mods = {}) {
    const nominals = { '2':2,'3':3,'4':4,'5':5,'6':6,'7':7,'8':8,'9':9,'10':10,
        Jack:10, Queen:10, King:10, Ace:11 };
    return { suit, value, nominal: nominals[value] || 0, ...mods };
}

function joker(key, name, opts = {}) {
    return { key, name, set: 'Joker', level: 1, edition: null, ...opts };
}

function compact(ante, round, hands, discards, chips_scored, chips_needed, dollars, deck_size) {
    return { state: 'SELECTING_HAND', ante, round, hands_left: hands, discards_left: discards,
             chips_scored, chips_needed, dollars, deck_size, joker_count: 2, consumable_count: 0 };
}

// ── Deck ─────────────────────────────────────────────────────
const SUITS = ['Spades', 'Hearts', 'Diamonds', 'Clubs'];
const VALUES = ['2','3','4','5','6','7','8','9','10','Jack','Queen','King','Ace'];
const FULL_DECK = [];
for (const s of SUITS) for (const v of VALUES) FULL_DECK.push(card(s, v));

// ── Simulation ───────────────────────────────────────────────

fs.writeSync(txtFd, '=== BALATRO RUN RECORDER (SIMULATION) ===\nSeed:  SIMULATE\nRun#:  1\n' +
    'Date:  ' + new Date().toISOString().replace('T', ' ').slice(0, 19) + '\n' +
    '='.repeat(40) + '\n\n');

// RUN_START
emit('RUN_START', {
    state_before: {},
    action: { seed: SEED, deck_key: 'b_red', stake: 1, challenge: null },
    resolution: {},
    state_after: compact(1,1,4,3,0,300,4,52),
});

// DECK_SNAPSHOT
emit('DECK_SNAPSHOT', {
    state_before: {}, action: {},
    resolution: { cards: FULL_DECK },
    state_after: {},
});

// Initial joker graph
emit('JOKER_GRAPH', {
    trigger: 'RUN_START',
    state_before: {}, action: {},
    resolution: { jokers: [
        joker('j_joker', 'Joker', { pos: 0 }),
        joker('j_greedy_joker', 'Greedy Joker', { pos: 1 }),
    ]},
    state_after: {},
});

// ── ANTE 1 ───────────────────────────────────────────────────

emit('STATE_CHANGE', {
    state_before: { state: 'SPLASH', G_STATE: 13 },
    action: {}, resolution: {},
    state_after: { state: 'BLIND_SELECT', G_STATE: 7 },
});

emit('BLIND_OPTIONS', {
    state_before: compact(1,1,4,3,0,0,4,52),
    action: {},
    resolution: {
        ante: 1,
        small: { key: 'bl_small', name: 'Small Blind', chips: 300 },
        big:   { key: 'bl_big',   name: 'Big Blind',   chips: 450 },
        boss:  { key: 'bl_the_needle', name: 'The Needle', chips: 600 },
        boss_reroll_available: false, boss_reroll_cost: 0,
    },
    state_after: {},
});

// Select small blind
emit('STATE_CHANGE', {
    state_before: { state: 'BLIND_SELECT', G_STATE: 7 },
    action: {}, resolution: {},
    state_after: { state: 'NEW_ROUND', G_STATE: 19 },
});

emit('ROUND_START', {
    state_before: compact(1,1,4,3,0,300,4,52),
    action: { blind_key: 'bl_small' },
    resolution: { blind_name: 'Small Blind', chips_needed: 300, boss: false },
    state_after: compact(1,1,4,3,0,300,4,52),
});

emit('STATE_CHANGE', {
    state_before: { state: 'NEW_ROUND', G_STATE: 19 },
    action: {}, resolution: {},
    state_after: { state: 'SELECTING_HAND', G_STATE: 1 },
});

emit('ROUND_RESOURCES', {
    state_before: {}, action: { trigger: 'ROUND_START' },
    resolution: { hands_remaining: 4, discards_remaining: 3 },
    state_after: compact(1,1,4,3,0,300,4,52),
});

// Hand 1: discard 2 bad cards
const dealt1 = [card('Clubs','2'), card('Spades','7'), card('Hearts','Ace'), card('Diamonds','Ace'), card('Clubs','Ace')];
emit('CARDS_DISCARDED', {
    state_before: compact(1,1,4,3,0,300,4,52),
    action: { cards: [card('Clubs','2'), card('Spades','7')] },
    resolution: {},
    state_after: compact(1,1,4,2,0,300,4,52),
});

emit('ROUND_RESOURCES', {
    state_before: compact(1,1,4,3,0,300,4,52),
    action: { trigger: 'AFTER_DISCARD' },
    resolution: { hands_remaining: 4, discards_remaining: 2 },
    state_after: compact(1,1,4,2,0,300,4,52),
});

// Draw 2 replacements → now have 3 Aces + King + Queen → play Three Aces
emit('STATE_CHANGE', {
    state_before: { state: 'SELECTING_HAND', G_STATE: 1 },
    action: {}, resolution: {},
    state_after: { state: 'HAND_PLAYED', G_STATE: 2 },
});

const playedCards = [card('Hearts','Ace'), card('Diamonds','Ace'), card('Clubs','Ace'), card('Spades','King'), card('Diamonds','Queen')];
emit('HAND_PLAYED', {
    state_before: compact(1,1,4,2,0,300,4,52),
    action: { cards: playedCards },
    resolution: {},
    state_after: compact(1,1,3,2,420,300,4,52),
});

emit('HAND_RESOLUTION', {
    state_before: compact(1,1,4,2,0,300,4,52),
    action: {},
    resolution: {
        hand_type: 'Three of a Kind',
        base: { hand_type: 'Three of a Kind', base_chips: 30, base_mult: 3 },
        joker_chain: [
            { source: 'j_joker',        pos: 0, chips_delta: 0,  mult_delta: 4  },
            { source: 'j_greedy_joker', pos: 1, mult_delta: 0,   xmult: 1.5    },
        ],
        final: { chips: 75, mult: 10.5, score: 787 },
        final_score: 420,
    },
    state_after: compact(1,1,3,2,420,300,4,52),
});

emit('ROUND_RESOURCES', {
    state_before: compact(1,1,4,2,0,300,4,52),
    action: { trigger: 'AFTER_HAND' },
    resolution: { hands_remaining: 3, discards_remaining: 2 },
    state_after: compact(1,1,3,2,420,300,4,52),
});

// Hand 2: play remaining hand → beat blind
emit('STATE_CHANGE', {
    state_before: { state: 'DRAW_TO_HAND', G_STATE: 3 },
    action: {}, resolution: {},
    state_after: { state: 'SELECTING_HAND', G_STATE: 1 },
});

emit('STATE_CHANGE', {
    state_before: { state: 'SELECTING_HAND', G_STATE: 1 },
    action: {}, resolution: {},
    state_after: { state: 'HAND_PLAYED', G_STATE: 2 },
});

const play2 = [card('Spades','King'), card('Diamonds','Queen'), card('Hearts','Jack'), card('Clubs','10'), card('Spades','9')];
emit('HAND_PLAYED', {
    state_before: compact(1,1,3,2,420,300,4,52),
    action: { cards: play2 },
    resolution: {},
    state_after: compact(1,1,2,2,420+320,300,4,52),
});

emit('HAND_RESOLUTION', {
    state_before: compact(1,1,3,2,420,300,4,52),
    action: {},
    resolution: {
        hand_type: 'Straight',
        base: { hand_type: 'Straight', base_chips: 30, base_mult: 4 },
        joker_chain: [
            { source: 'j_joker',        pos: 0, mult_delta: 4  },
            { source: 'j_greedy_joker', pos: 1, xmult: 1.5    },
        ],
        final: { chips: 80, mult: 12, score: 960 },
        final_score: 420 + 320,
    },
    state_after: compact(1,1,2,2,740,300,4,52),
});

emit('ROUND_WON', {
    state_before: compact(1,1,2,2,740,300,4,52),
    action: {},
    resolution: { chips_scored: 740, chips_needed: 300, dollars_after: 9 },
    state_after: compact(1,2,4,3,0,450,9,52),
});

// Blind reward money
emit('MONEY_CHANGE', {
    state_before: { dollars: 4 },
    action: { delta: 4, source: 'BLIND_REWARD', detail: 'small_blind' },
    resolution: { balance_after: 8 },
    state_after: {},
});

emit('MONEY_CHANGE', {
    state_before: { dollars: 8 },
    action: { delta: 1, source: 'INTEREST', detail: 'floor(4/5)=0 -> base $1' },
    resolution: { balance_after: 9 },
    state_after: {},
});

// ── SHOP ──────────────────────────────────────────────────────

emit('STATE_CHANGE', {
    state_before: { state: 'ROUND_EVAL', G_STATE: 8 },
    action: {}, resolution: {},
    state_after: { state: 'SHOP', G_STATE: 5 },
});

emit('SHOP_INVENTORY', {
    state_before: compact(1,2,4,3,0,450,9,52),
    action: { reroll_number: 0, reroll_cost: 5 },
    resolution: { slots: [
        { slot: 'joker_1',   key: 'j_blueprint',     name: 'Blueprint',     set: 'Joker',   cost: 8,  edition: null },
        { slot: 'joker_2',   key: 'j_mime',           name: 'Mime',          set: 'Joker',   cost: 5,  edition: 'foil' },
        { slot: 'voucher_1', key: 'v_reroll_surplus', name: 'Reroll Surplus',set: 'Voucher', cost: 10, edition: null },
        { slot: 'booster_1', key: 'p_arcane_pack',    name: 'Arcane Pack',   set: 'Booster', cost: 4,  edition: null },
        { slot: 'booster_2', key: 'p_buffoon_pack_normal_1', name: 'Buffoon Pack', set: 'Booster', cost: 4, edition: null },
    ]},
    state_after: compact(1,2,4,3,0,450,9,52),
});

emit('CONSUMABLE_SNAPSHOT', {
    state_before: compact(1,2,4,3,0,450,9,52),
    action: { trigger: 'SHOP_ENTER' },
    resolution: { consumables: [] },
    state_after: {},
});

// Reroll (can't afford Blueprint)
emit('SHOP_REROLL', {
    state_before: compact(1,2,4,3,0,450,9,52),
    action: { reroll_cost: 5 },
    resolution: {},
    state_after: compact(1,2,4,3,0,450,4,52),
});

emit('MONEY_CHANGE', {
    state_before: { dollars: 9 },
    action: { delta: -5, source: 'SHOP_REROLL', detail: 'reroll_1' },
    resolution: { balance_after: 4 },
    state_after: {},
});

emit('SHOP_INVENTORY', {
    state_before: compact(1,2,4,3,0,450,4,52),
    action: { reroll_number: 1, reroll_cost: 6 },
    resolution: { slots: [
        { slot: 'joker_1',   key: 'j_scary_face',  name: 'Scary Face',  set: 'Joker',   cost: 5, edition: null },
        { slot: 'joker_2',   key: 'j_hack',        name: 'Hack',        set: 'Joker',   cost: 5, edition: 'holo' },
        { slot: 'voucher_1', key: 'v_reroll_surplus', name: 'Reroll Surplus', set: 'Voucher', cost: 10, edition: null },
        { slot: 'booster_1', key: 'p_standard_pack', name: 'Standard Pack', set: 'Booster', cost: 4, edition: null },
        { slot: 'booster_2', key: 'p_celestial_pack', name: 'Celestial Pack', set: 'Booster', cost: 4, edition: null },
    ]},
    state_after: compact(1,2,4,3,0,450,4,52),
});

// Buy Hack joker
emit('SHOP_BUY', {
    state_before: compact(1,2,4,3,0,450,4,52),
    action: { item: { key:'j_hack', name:'Hack', set:'Joker', cost:5, edition:'holo' }, item_key: 'j_hack' },
    resolution: { cost: 5 },
    state_after: compact(1,2,4,3,0,450,-1,52),
});

emit('MONEY_CHANGE', {
    state_before: { dollars: 4 },
    action: { delta: -5, source: 'SHOP_BUY', detail: 'j_hack' },
    resolution: { balance_after: -1 },
    state_after: {},
});

emit('JOKER_GRAPH', {
    trigger: 'AFTER_BUY',
    state_before: {}, action: {},
    resolution: { jokers: [
        joker('j_joker',        'Joker',        { pos: 0 }),
        joker('j_greedy_joker', 'Greedy Joker', { pos: 1 }),
        joker('j_hack',         'Hack',          { pos: 2, edition: 'holo' }),
    ]},
    state_after: {},
});

// Buy booster pack — open it
emit('SHOP_BUY', {
    state_before: compact(1,2,4,3,0,450,-1,52),
    action: { item: { key:'p_celestial_pack', name:'Celestial Pack', set:'Booster', cost:4 }, item_key: 'p_celestial_pack' },
    resolution: { cost: 0 },  // free with coupon
    state_after: compact(1,2,4,3,0,450,-1,52),
});

emit('STATE_CHANGE', {
    state_before: { state: 'SHOP', G_STATE: 5 },
    action: {}, resolution: {},
    state_after: { state: 'PLANET_PACK', G_STATE: 10 },
});

emit('PACK_OPENED', {
    state_before: compact(1,2,4,3,0,450,-1,52),
    action: {
        pack_key: 'p_celestial_pack',
        options: ['c_mercury', 'c_venus', 'c_earth'],
        selected_index: 2,
        selected: 'c_earth',
    },
    resolution: {},
    state_after: compact(1,2,4,3,0,450,-1,52),
});

emit('STATE_CHANGE', {
    state_before: { state: 'PLANET_PACK', G_STATE: 10 },
    action: {}, resolution: {},
    state_after: { state: 'SHOP', G_STATE: 5 },
});

// Leave shop
emit('STATE_CHANGE', {
    state_before: { state: 'SHOP', G_STATE: 5 },
    action: {}, resolution: {},
    state_after: { state: 'BLIND_SELECT', G_STATE: 7 },
});

// ── ANTE 1 BIG BLIND ────────────────────────────────────────

emit('BLIND_OPTIONS', {
    state_before: compact(1,2,4,3,0,450,-1,52),
    action: {},
    resolution: {
        ante: 1,
        small: { key: 'bl_small', name: 'Small Blind', chips: 300 },
        big:   { key: 'bl_big',   name: 'Big Blind',   chips: 450 },
        boss:  { key: 'bl_the_needle', name: 'The Needle', chips: 600 },
        boss_reroll_available: false, boss_reroll_cost: 0,
    },
    state_after: {},
});

// Skip big blind → earn tag
emit('BLIND_OPTIONS', {
    state_before: compact(1,2,4,3,0,450,-1,52),
    action: { skipped: true },
    resolution: { tag_earned: 'tag_negative' },
    state_after: {},
});

// ── ANTE 1 BOSS: The Needle ──────────────────────────────────

emit('ROUND_START', {
    state_before: compact(1,3,4,3,0,600,-1,52),
    action: { blind_key: 'bl_the_needle' },
    resolution: { blind_name: 'The Needle', chips_needed: 600, boss: true },
    state_after: compact(1,3,4,3,0,600,-1,52),
});

emit('BOSS_BLIND_ACTIVE', {
    state_before: compact(1,3,4,3,0,600,-1,52),
    action: {},
    resolution: {
        key: 'bl_the_needle',
        name: 'The Needle',
        effect: 'play_only_one_hand',
    },
    state_after: compact(1,3,1,3,0,600,-1,52),
});

emit('ROUND_RESOURCES', {
    state_before: {}, action: { trigger: 'ROUND_START' },
    resolution: { hands_remaining: 1, discards_remaining: 3 },
    state_after: compact(1,3,1,3,0,600,-1,52),
});

// One shot — play a Flush
emit('STATE_CHANGE', {
    state_before: { state: 'SELECTING_HAND', G_STATE: 1 },
    action: {}, resolution: {},
    state_after: { state: 'HAND_PLAYED', G_STATE: 2 },
});

const flushCards = [
    card('Spades','Ace',{ edition:'foil' }),
    card('Spades','King'),
    card('Spades','Queen'),
    card('Spades','Jack'),
    card('Spades','9'),
];

emit('HAND_PLAYED', {
    state_before: compact(1,3,1,3,0,600,-1,52),
    action: { cards: flushCards },
    resolution: {},
    state_after: compact(1,3,0,3,850,600,-1,52),
});

emit('HAND_RESOLUTION', {
    state_before: compact(1,3,1,3,0,600,-1,52),
    action: {},
    resolution: {
        hand_type: 'Flush',
        base: { hand_type: 'Flush', base_chips: 35, base_mult: 4 },
        joker_chain: [
            { source: 'j_joker',        pos: 0, mult_delta: 4  },
            { source: 'j_greedy_joker', pos: 1, xmult: 2.0    },
            { source: 'j_hack',         pos: 2, chips_delta: 30 },
        ],
        final: { chips: 115, mult: 16, score: 1840 },
        final_score: 850,
    },
    state_after: compact(1,3,0,3,850,600,-1,52),
});

emit('ROUND_WON', {
    state_before: compact(1,3,0,3,850,600,-1,52),
    action: {},
    resolution: { chips_scored: 850, chips_needed: 600, dollars_after: 4 },
    state_after: compact(2,4,4,3,0,900,4,52),
});

emit('MONEY_CHANGE', {
    state_before: { dollars: -1 },
    action: { delta: 5, source: 'BLIND_REWARD', detail: 'boss_blind' },
    resolution: { balance_after: 4 },
    state_after: {},
});

// ── GAME OVER (simulate losing ante 2 boss) ──────────────────

emit('STATE_CHANGE', {
    state_before: { state: 'SELECTING_HAND', G_STATE: 1 },
    action: {}, resolution: {},
    state_after: { state: 'GAME_OVER', G_STATE: 4 },
});

emit('GAME_OVER', {
    state_before: compact(2,7,0,0,420,2100,8,52),
    action: {},
    resolution: { ante: 2, round: 7, dollars: 8 },
    state_after: {},
});

// ────────────────────────────────────────────────────────────

fs.closeSync(jsonlFd);
fs.closeSync(txtFd);

console.log(`\nSimulation complete! Generated:`);
console.log(`  ${BASE}.jsonl`);
console.log(`  ${BASE}.txt`);
console.log(`\n${seq} events written.`);
console.log(`\nOpen replay.html and drop the .jsonl file onto it to view the replay.`);
