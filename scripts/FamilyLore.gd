extends RefCounted

# ============================================================
# FamilyLore.gd — Run 117 (2026-07-01) — THE DIALOGUE HOME
# ============================================================
#
#   ██████████████████████████████████████████████████████████
#   █  BRUNO: ALL FAMILY DIALOGUE LIVES IN THIS ONE FILE.     █
#   █  Add lines to the DIALOG dictionary below — nothing     █
#   █  else needs to change. Empty pools fall back to the     █
#   █  GENERIC lines so the game always works mid-writing.    █
#   ██████████████████████████████████████████████████████████
#
# Structure — DIALOG[family][tier][pool] = Array of String lines.
#
#   family : "Apple" "Coconut" "Broccoli" "Carrot" "Grape"
#            "Watermelon" "Pepper" "Potato" "Banana" "Onion"
#   tier   : 0 = Rotten   (moldy, slumped, fragmented speech)
#            1 = Wilted   (upright, pale, anxious but clearer)
#            2 = Ripe     (vibrant, grateful, helpful)
#            3 = Restored (fully human, real personality)
#   pool   : "daily"    — small talk; ROTATES each visit, add as many as
#                         you want so they have something new every day
#            "story"    — the family's darker-secret reveal; ONE new layer
#                         plays per karma deposit, in order; add layers
#                         freely, they never repeat until tier changes
#            "deposit"  — reaction when karma is deposited (random pick)
#            "tier_up"  — the healing moment when they advance a tier
#                         (read from the NEW tier's pool)
#            "no_karma" — visit with nothing to deposit (random pick)
#
# The Apple family is fully written out as the TEMPLATE — copy its shape.
# {hero} in any line is replaced with the controlled hero's name.
#
# Elder (the karma drop-off, never leaves the house) per Family_Roster.md.
# Wanderers stroll around outside the hut in the biome day-room.
# ============================================================

const ELDERS: Dictionary = {
	"Apple":      "Granny Idunn",
	"Coconut":    "Gnarls",
	"Broccoli":   "Broc Lee",
	"Carrot":     "Fletch",
	"Grape":      "Nonna Vitti",
	"Watermelon": "Auntie July",
	"Pepper":     "Flambeau",
	"Potato":     "Russel",
	"Banana":     "Splitz",
	"Onion":      "Alliam",
}

# Placeholder wanderer names (household members who stroll outside).
# [PROPOSED] — rename freely; household compositions per Family_Roster.md §4.
const WANDERERS: Dictionary = {
	"Apple":      ["Blossom", "Pip"],
	"Coconut":    ["Kai", "Shelly"],
	"Broccoli":   ["Roman", "Remy"],
	"Carrot":     ["Scout"],
	"Grape":      ["Welchie", "Mani"],
	"Watermelon": ["Wally", "Bobby"],
	"Pepper":     ["Rika", "Niño"],
	"Potato":     ["Tot", "Wedge"],
	"Banana":     ["Nanette"],
	"Onion":      ["Lottie", "Pearl"],
}

# ---------------------------------------------------------------------------
# ███ MEMBER DIALOGUE — the non-elder household members ███
# ---------------------------------------------------------------------------
# The elders own the karma drop-off + story/tier_up pools (DIALOG above).
# Everyone ELSE — the wanderers strolling the yard — gets rotating daily-style
# lines only, here. Structure mirrors DIALOG but keyed by member name:
#   MEMBER_DIALOG[family][member][tier] = Array of String lines.
# Line count grows as they heal — more of their story surfaces at each tier:
#   tier 0 = 2 lines   tier 1 = 3   tier 2 = 3   tier 3 = 4 (lore payoffs).
# {hero} is replaced with the controlled hero's name. Empty/missing members
# fall back to GENERIC_MEMBER so every walker is always talkable.
# ---------------------------------------------------------------------------
const MEMBER_DIALOG: Dictionary = {

	# ── APPLE — Frostpeak hearth-keepers (Granny Idunn's family) ────────────
	"Apple": {
		"Cormac": {   # Granny's adult son — weary, in denial
			0: [
				"...Ma's just tired... she'll... bake tomorrow...",
				"...the cider's cold... it's always... cold now...",
			],
			1: [
				"Morning, {hero}. Ma had a good night. See? She's getting better. She IS.",
				"I keep the hearth stoked day and night. Warmth fixes things. It has to.",
				"The cold up here used to stay outside. Now it gets in the bones. Our job's to hold it back — I'm trying, {hero}.",
			],
			2: [
				"{hero}! Cider's hot, quilts are stacked. Frostpeak stays warm because WE keep it warm. Feels good to say that again.",
				"Ma taught me every knot in these quilts. I finally sat still long enough to listen.",
				"The blizzards eased since we mended. That's the duty working — a hearth-keeper's warmth pushing back the bitter cold.",
			],
			3: [
				"Human hands, {hero}. I remember these hands — kneading dough beside Ma when I was a boy. We were always people. I'd forgotten.",
				"I stopped pretending she'll live forever. I'd rather have her today, real and warm, than lie to myself another winter.",
				"When I was rotten, the cold felt like the whole truth — like grief was all that was left. It wasn't. There was cider and quilts and her, the whole time.",
				"Blossom and Pip still call her Granny. I hope they always remember she was a person who loved them, not a curse that lifted.",
			],
		},
		"Blossom": {   # kid
			0: [
				"...is Granny... gonna be okay...? nobody... tells me...",
				"...it's cold... I don't like it... cold...",
			],
			1: [
				"Hi {hero}. Granny knitted me a scarf. It's a little lumpy but I love it.",
				"Papa says warmth fixes everything. Do you think it fixes Granny too?",
				"I helped stir the cider today! Granny says keeping folks warm is the most important job on the whole mountain.",
			],
			2: [
				"{hero}! Look — I knitted a WHOLE mitten! Granny only helped a little!",
				"The snow's not so scary now. Granny says that's 'cause our hearth is strong again.",
				"Me and Pip are gonna be hearth-keepers when we grow up. Granny's teaching us her secret cider spices.",
			],
			3: [
				"I'm a real girl, {hero}! I have fingers and everything! I always did, I just couldn't remember!",
				"Papa doesn't cry as much now. He hugs Granny instead. I like that better.",
				"When I was the moldy me, everything felt far away, like being under too many blankets. Now I can feel Granny's hand when she holds mine.",
				"Granny showed me the quilt she's making for ME. She says a piece of her stays warm in every stitch. I'm gonna keep it forever.",
			],
		},
		"Pip": {   # younger kid, tree-climber
			0: [
				"...I climbed... but the branch... was all soft... and wrong...",
				"...hungry... but the apples... taste gray...",
			],
			1: [
				"{hero}! I climbed the tree by the door! Only fell once!",
				"Granny gave me hot cider. It made my tummy warm all the way down.",
				"Papa keeps the fire big so nobody's cold. That's OUR job, keeping the mountain warm. He told me.",
			],
			2: [
				"Watch this, {hero}! I climbed ALL the way up and I could see the whole snowy peak!",
				"Granny let me carry quilts to the neighbors. They said thank you like a hundred times.",
				"The cold monsters don't come around no more. Blossom says our hearth got strong again. I say it's 'cause I'm brave.",
			],
			3: [
				"I got real toes now, {hero}! Wanna see me wiggle 'em?!",
				"I remember being a kid before, a long time ago. We were people who lived on a mountain. Weird, huh?",
				"Being rotten felt like a bad dream where you can't run fast. Now I can run SUPER fast! Watch!",
				"Granny's gonna teach me to knit even though I said knitting's for Blossom. She says warm hands come from warm hearts. I dunno what that means but okay.",
			],
		},
	},

	# ── COCONUT — Beach tide-breaker surfers (Gnarls' family) ───────────────
	"Coconut": {
		"Piña": {   # other parent — overworked, walled-off
			0: [
				"...work... always more... work... can't stop...",
				"...the tide... it doesn't... obey us... anymore...",
			],
			1: [
				"Morning, {hero}. Gnarls and I ate breakfast sitting DOWN today. Small thing. Felt huge.",
				"I used to think a good parent was a busy parent. The walls I built... I'm learning to lower them.",
				"Our job's to break the big tides before they swallow the beach. When we rotted, the surf ran wild. We're steadying it again.",
			],
			2: [
				"{hero}! Kai's on a board for the first time in years. Gnarls is out there whooping like a kid.",
				"We ride the tides so the beach stays safe. Feels good to command the water again instead of drowning in work.",
				"Shelly held my hand on the walk down. I didn't let go first this time.",
			],
			3: [
				"Human hands, {hero}. I remember now — we were beach folk, surfers, a family. The waves were always ours to ride.",
				"The curse taught me what work never could: my kids don't need a provider, they need a parent who's THERE.",
				"When we were rotten the tide felt like an enemy, this cold crushing thing. Turns out we just forgot how to ride it together.",
				"Gnarls and I break the morning waves side by side now. Then we come home for breakfast. Both things. That's the whole trick, isn't it?",
			],
		},
		"Kai": {   # kid — stopped asking to play
			0: [
				"...I stopped... asking... they never... had time...",
				"...the waves... too loud... too gray...",
			],
			1: [
				"Hey {hero}. Dad said he'd teach me to surf. He actually said it. Out loud.",
				"I used to just watch the water alone. It's less lonely lately.",
				"Mom says breaking the big tides is the family job. I wanna help. If they'll let me.",
			],
			2: [
				"{hero}! I stood up on the board! Dad caught me when I wiped out. He was RIGHT there.",
				"We're tide-breakers. Warriors of the beach! Dad's teaching me to read the swell.",
				"Shelly and me built a sandcastle and Mom helped instead of working. Weird. Good weird.",
			],
			3: [
				"I'm a real kid, {hero}! Look, real feet for the sand!",
				"I remember before the curse, kind of. Mom and Dad used to be around more. Then they weren't. Now they are again.",
				"Being rotten felt like shouting underwater and nobody hearing. Now Dad hears me even when I whisper.",
				"Dad says one day I'll break the morning tide by myself. I told him I'd rather do it WITH him. He got all quiet and hugged me.",
			],
		},
		"Shelly": {   # kid — reaches for Dad's hand
			0: [
				"...Daddy won't... hold my hand... his hands are... hard...",
				"...cold water... everywhere... cold...",
			],
			1: [
				"Hi {hero}! Daddy let me hold his pinky today. Just the pinky. But still!",
				"Mommy smiled this morning. I almost forgot what that looked like.",
				"We keep the beach safe from the mean big waves. That's a warrior job! I'm gonna be a warrior.",
			],
			2: [
				"{hero}! Daddy HUGGED me and he didn't let go first! I counted, it was so long!",
				"I collected shells and Mommy looked at every single one. Every one!",
				"The scary tides don't crash the beach no more. Kai says our family got strong again inside.",
			],
			3: [
				"I got REAL hands now, {hero}! Perfect for holding Daddy's!",
				"We were always people, Daddy told me. Just huggy beach people who forgot how to hug for a while.",
				"When I was moldy everything felt hard and faraway, like Daddy. Now everything's soft, and Daddy's soft too. Shh, don't tell him I said.",
				"Daddy's teaching me to float on the little waves. He says warriors gotta be soft as water AND strong as the tide. I like the soft part best.",
			],
		},
	},

	# ── BANANA — Jungle performer troupe (Splitz's family) ──────────────────
	"Banana": {
		"Nanette": {   # small fearless showgirl kid
			0: [
				"...I keep singing... but nobody... claps... not even... Papa...",
				"...the jungle's... so quiet... so gray...",
			],
			1: [
				"{hero}! Papa hummed today! I heard him! I pretended not to so he wouldn't stop!",
				"I do my little show for the jungle critters. Somebody's gotta keep everybody's spirits up!",
				"Papa used to be a STAR. I'm gonna make him remember. Watch me do a cartwheel!",
			],
			2: [
				"{hero}! Papa SANG! A whole song! For me! I cried a little but the happy kind!",
				"We're the jungle's cheer-uppers. When we do our act, even the grumpy vines perk up. It's our job!",
				"I'm writing us a duet. Papa says he's scared but I told him scared is just excited wearing a silly hat.",
			],
			3: [
				"Look {hero}, real hands for real jazz-hands! Ta-da!",
				"Papa says we used to be people who put on shows, way back. I don't remember but I believe him 'cause I LOVE shows.",
				"When I was the sad gray me, my songs came out wrong and quiet. Now they come out LOUD and the whole jungle can hear!",
				"Papa and me are doing our duet at the festival. He's shakin' in his boots. I'm holdin' his hand. The show's gonna go on!",
			],
		},
	},

	# ── BROCCOLI — Jungle strongman beast-trainers (Broc Lee's family) ──────
	"Broccoli": {
		"Roman": {   # twin who strains to measure up
			0: [
				"...Remy's always... stronger... always... first...",
				"...the beasts... they're loose... I can't... hold them...",
			],
			1: [
				"Morning, {hero}. Did an extra hundred reps before Remy woke. Gotta stay ahead. Gotta.",
				"Pa says I don't need to beat Remy. Easy for him to say — he's not the second-best twin.",
				"We keep the jungle beasts in line. When we're weak, they run wild. So I train. Always.",
			],
			2: [
				"{hero}! Remy spotted me on a lift today and I spotted him. We weren't racing. It was... nice.",
				"Turns out wrangling a rampage-beast works better with two of us pulling together. Who knew.",
				"Pa says strength that competes crumbles, strength that carries holds. Starting to get it.",
			],
			3: [
				"Real arms, {hero}, and they're MINE — not 'the weaker twin's.' Just mine. Feels good.",
				"I remember being a person, training beside Remy as boys, laughing. Somewhere I turned it into a war. It was never supposed to be one.",
				"Rotten, I only felt what I lacked — every ounce Remy could lift that I couldn't. Now I feel what we've got: each other.",
				"Remy and me drove a whole herd back into the deep jungle this morning, in sync, no scoreboard. Pa watched and just nodded. That nod was everything.",
			],
		},
		"Remy": {   # oblivious/easygoing twin
			0: [
				"...Roman seems... mad again... dunno why...",
				"...beasts are stompin'... everything's... a mess...",
			],
			1: [
				"Hey {hero}! Beautiful morning. Roman's already training — that guy never stops, ha!",
				"I asked Roman to spot me. He looked surprised. Was that weird? Seemed normal to me.",
				"We keep the big jungle critters from trampling folks. Fun job when Roman lightens up!",
			],
			2: [
				"{hero}! Me and Roman herded a beast together and he actually smiled. Nice to see, he's so serious.",
				"I never got why Roman pushed so hard. He's plenty strong! Anyway, we're a good team now.",
				"Pa says we're 'carrying each other.' I just think it's more fun with my brother, honestly.",
			],
			3: [
				"Real hands, {hero}! Great for flexing AND for high-fiving Roman!",
				"Huh, I remember being a kid person, wrestling Roman in the mud. Good times. Guess we always were people!",
				"When I was rotten everything felt heavy and pointless. Didn't think much, just felt gray. Glad THAT'S over!",
				"Found out Roman felt like he was always losing to me. Never even knew we were racing! Told him I'd rather have a brother than a trophy. He got misty. Big softie.",
			],
		},
	},

	# ── PEPPER — Caverns lava-wardens & canteen crew (Flambeau's family) ────
	"Pepper": {
		"Rika": {   # middle sibling — dry, sardonic
			0: [
				"...canteen's cold... crews go hungry... whose fault... take a guess...",
				"...lava's creepin'... nobody's watchin' it... great...",
			],
			1: [
				"Oh, {hero}. I only glared at Niño twice this morning. Personal record.",
				"The miners still shuffle in expecting a hot meal. We used to feed the whole crew. Used to.",
				"We're lava wardens — tame the flow, feed the crews. Real inspiring when we can't even feed ourselves.",
			],
			2: [
				"{hero}! The canteen served forty bowls today. Hot ones. Nobody threw a single one. Growth.",
				"Flambeau, Niño and me split the shifts fair. I know. I'm as shocked as you.",
				"Steered the lava back into its channel this morning. Warding the volcano's easier when you're not busy warding off your own siblings.",
			],
			3: [
				"Real hands, {hero}. Perfect for chopping onions and, apparently, for NOT throwing pans. Multitalented.",
				"I remember now — we were people who ran a canteen, fed the miners, watched the mountain. The bickering was ours too, but so was the family.",
				"When we were rotten, every problem had a name and the name was always a sibling. Turns out the real problem was three cooks who forgot they were on the same side.",
				"The crews packed the canteen today. Flambeau's crying into the stew, Niño's laughing at my jokes. Don't tell them I like this. I have a reputation.",
			],
		},
		"Niño": {   # youngest — hotheaded
			0: [
				"...NOT my fault... the canteen... NONE of it...",
				"...everything BURNS... I can't... make it stop...",
			],
			1: [
				"{hero}. I made a sauce today and DIDN'T ask what anyone thought. It was good. It was MINE.",
				"Rika thinks I'm a hothead. Fine. Somebody in this family's gotta have fire.",
				"We're lava wardens. Fire's the whole job! I'm BUILT for it — if they'd let me near the flow.",
			],
			2: [
				"{hero}! Flambeau asked ME for a menu idea. Not approval. An IDEA. Like I matter!",
				"Cooked next to Rika and neither of us yelled. Weird. Kinda good weird.",
				"I channeled the lava back today, all by feel. Flambeau said I've got a gift for it. First time anybody said I had a gift for anything.",
			],
			3: [
				"Real hands, {hero}, and they run HOT — perfect for a warden AND a chef!",
				"I remember being a little kid, stealing spoonfuls from Flambeau's pot. We were always a family. I just yelled so loud I couldn't hear it.",
				"Rotten, all I felt was blame — mine, theirs, everybody's. The fire had nowhere to go but out. Now it goes into the food and the flow. Way better.",
				"Grand reopening's soon and I'M on sauce. Flambeau trusts me with it. Rika even said mine's better than hers. I'm never letting her forget she said that.",
			],
		},
	},

	# ── POTATO — Caverns miners (Russel's family) ───────────────────────────
	"Potato": {
		"Ida": {   # Russel's wife — quietly practical, sees everything
			0: [
				"...he won't ask... for help... never has... never will...",
				"...the veins are... empty... but he keeps... digging...",
			],
			1: [
				"Morning, {hero}. Russel thinks I don't notice how tired he is. I notice everything. That's my job.",
				"The gem veins dried up seasons ago. He'd sooner break his back than say the word 'help.' Stubborn old root.",
				"We mine the deep minerals — feeds the family and half the market besides. Hard to feed anyone from an empty seam.",
			],
			2: [
				"{hero}! Three fresh veins this week. And Russel let Wedge ask the neighbors for advice. I nearly fainted.",
				"I run the ledgers, patch the tools, and know exactly which son skipped breakfast. Someone has to see clearly.",
				"The Pepper canteen sends hot meals down to our crew again. A warm belly digs twice as deep — Russel won't admit it, but I sent Flambeau a thank-you.",
			],
			3: [
				"Real hands, {hero}. I remember these — mending shirts by lamplight while Russel snored. We were always just people down a mine.",
				"I always knew we were more than the ore. Took the curse to make HIM see it. I just had to wait him out, like I always do.",
				"When we were rotten, I still saw everything — I just couldn't move to fix it. Watching your family fade while you're frozen? That's the real curse.",
				"Russel asked Tot for help lifting a beam yesterday. Out loud. I didn't say a word. Just squeezed his hand. He knew what it meant.",
			],
		},
		"Tot": {   # hardworking son
			0: [
				"...dig... don't stop... Pa says... don't stop...",
				"...rocks are gray... everything's... gray dust...",
			],
			1: [
				"Hey {hero}. Found one green mineral in the dark today. Just one. But I saved it to show Pa.",
				"Pa says a Potato never quits. My hands are blistered but I won't quit either.",
				"We're miners — we dig the gems that keep the whole island trading. Wedge and me are gonna bring the veins back. Somehow.",
			],
			2: [
				"{hero}! The south seam's glittering again! Ma says it's the best haul since the blight!",
				"I asked the Broccoli twins how they haul heavy loads. Pa almost said no. Then he didn't. Felt like a door opening.",
				"Rika from the canteen sends stew down the shaft now. Eating hot makes the digging feel less endless, y'know?",
			],
			3: [
				"Real hands, {hero}! Ten real fingers, only two blisters!",
				"I remember being a boy who liked shiny rocks, before all this. Guess I still am. Guess we were always people who loved the deep places.",
				"Being rotten was like digging forever and the tunnel never ending. Now every swing goes somewhere. Every one.",
				"Pa asked ME to lead the new dig. ME, not Wedge. Said I've got a good eye for the seam. I'm gonna make him proud, {hero}.",
			],
		},
		"Wedge": {   # hardworking son
			0: [
				"...Pa says handle... our own... so I... handle it...",
				"...tired... so tired... but Potatoes... don't rest...",
			],
			1: [
				"Morning, {hero}. Reinforced the tunnels before dawn. If we're gonna dig, we dig SAFE.",
				"I keep wanting to ask the neighbors how they beat the blight. Pa's pride is a heavy thing to dig around.",
				"We mine to feed the family and trade the surplus. Honest work. I just wish it still paid out.",
			],
			2: [
				"{hero}! I finally asked a neighbor about draining the flooded pools. Pa didn't stop me! Progress!",
				"Tot found the vein but I shored it up so it'll last. We're a good pair, my brother and me.",
				"Ma says I see the practical side, like her. Somebody's gotta keep the tunnels standing while everyone dreams big.",
			],
			3: [
				"Real hands, {hero}. Strong ones — good for hauling AND for shaking a neighbor's hand when you ask for help.",
				"I remember now — we were mining folk for generations, real people, real pride. The pride's fine. It just can't come before family.",
				"When we were rotten I only knew the next swing of the pick. No past, no future, just gray labor. Now I know why I dig: for them.",
				"Pa said 'thank you' to a neighbor this week. Out loud, where people could hear. Fifteen years I waited for that. Worth it.",
			],
		},
	},

	# ── ONION — Swamp shaman-alchemists (Alliam's family) ───────────────────
	"Onion": {
		"Lottie": {   # adult child — practical apothecary
			0: [
				"...Father sets... two cups out... she's been gone... years...",
				"...the fog's thick... my remedies... won't set... right...",
			],
			1: [
				"Morning, {hero}. Father told a story about Mother today without his voice cracking. That's new.",
				"I mix the remedies now — someone has to. The fog doesn't ward itself while he grieves.",
				"We're the swamp's alchemists. Our tonics keep the poison mist back and the fevers down. When our hearts fogged over, so did the bog. I'm clearing both.",
			],
			2: [
				"{hero}! Father laughed at one of Pearl's jokes. A real laugh. I'd almost forgotten the sound.",
				"Brewed a whole batch of fog-ward tonic today. The eastern paths are breathable again — that's OUR work holding.",
				"I keep this apothecary running on habit and stubbornness. Grief nearly drowned this house; I wasn't about to let it take the practice too.",
			],
			3: [
				"Real hands, {hero}. Steady ones — good for measuring tinctures and for holding my father's when he needs it.",
				"I remember Mother now, clear as anything. We were people, a family of healers. Losing her was real. So was everything after — Father just forgot the 'after' could be good.",
				"When we were rotten, my remedies curdled and so did I. Grief with no bottom. Turns out the cure was letting the living matter as much as the lost.",
				"Pearl's learning to gather the swamp herbs, Father's teaching her the old songs Mother sang. Three generations, one apothecary. Mother would've loved the noise.",
			],
		},
		"Pearl": {   # grandchild — herb-gatherer kid
			0: [
				"...Grandpa's always... sad... is it 'cause... of me...?",
				"...the fog stings... my eyes... makes 'em water...",
			],
			1: [
				"Hi {hero}! I found three good herbs in the bog today. Auntie Lottie says they're for the cough tonic!",
				"Grandpa told me about Grandma. She used to sing. I asked him to sing it. He almost did.",
				"We make medicines that keep the swamp-fog away! I'm the herb-gatherer. It's important — the fog is POISON, y'know.",
			],
			2: [
				"{hero}! Grandpa taught me Grandma's herb song! I sang it in the bog and it wasn't scary anymore!",
				"I gathered a whole basket of fog-ward leaves! Auntie says I've got the family's green thumb.",
				"Grandpa smiles more now. I don't have to be quiet-happy anymore. I can be LOUD-happy!",
			],
			3: [
				"Look {hero}, real hands for pickin' herbs! Ten little fingers, perfect for the tiny leaves!",
				"Grandpa says we were always people, way before I was born even. A family who healed folks in the swamp. I like that we help people.",
				"When I was the moldy me, the fog got in my eyes and everything looked blurry and sad, like Grandpa. Now I can see all the little herbs again!",
				"Grandpa put wildflowers by Grandma's picture — the ones I picked! He said she's watching us gather herbs and she's happy. So I'm happy too.",
			],
		},
	},

	# ── GRAPE — Swamp Vineguard warband (Nonna Vitti's family) ──────────────
	"Grape": {
		"Welchie": {   # grown squad-fighter
			0: [
				"...too crowded... this house... can't... breathe...",
				"...bog paths... all tangled... nobody's... clearing 'em...",
			],
			1: [
				"Morning, {hero}. Took a walk alone this morning. Didn't slam the door. Nonna noticed. Baby steps.",
				"Mani and I fight like cats indoors, but put a vine-whip in our hands and we move like one. Funny how that works.",
				"We're the Vineguard — we lash the bog paths clear so folks can cross safe. When we rotted, the swamp swallowed the trails. We're reopening them.",
			],
			2: [
				"{hero}! Cleared the whole north causeway with Mani today. Perfect formation. THEN we argued about lunch. Ha!",
				"Nonna's letting me drill the younger fighters. Says I've got the footwork. High praise from an old war-captain.",
				"The bog paths are open again — merchants can cross, kids can play. That's the Vineguard's whole purpose, beating in us again.",
			],
			3: [
				"Real hands, {hero}, gripping a real vine-lash. Feels like coming home to something I never knew I'd lost.",
				"I remember now — we were people, a whole warband, generations of us guarding these bogs. The bickering's just family. Fighting as one, that's who we ARE.",
				"When we were rotten I only felt crowded, smothered by my own bunch. Now I get it: we grow in our own directions but we fight from the same root.",
				"Mani wants her own place across the bog. I told her go — a vine's stronger with room to climb. Nonna taught us that, even if it took a curse to hear it.",
			],
		},
		"Mani": {   # grown squad-fighter
			0: [
				"...Welchie's always... in my space... always...",
				"...I want... my own room... my own... anything...",
			],
			1: [
				"Hey {hero}. Welchie didn't hog the whole hut this morning. I nearly framed the moment.",
				"We snipe at each other all day, but out on the bog paths? Welchie and I are one weapon. Don't ask me how.",
				"The Vineguard keeps the swamp crossings open. That's us — vine-lash formation fighters. The trails went wild when we did; we're taming them back.",
			],
			2: [
				"{hero}! Started my own herb garden out back — MINE, nobody else's. Nonna's biting her tongue not to take over. I see it. I appreciate it.",
				"Welchie and I ran the eastern patrol without one argument in the field. In the FIELD, mind you. At dinner we made up for it.",
				"Nonna says my vine-work's the cleanest in the guard. From her, that's practically a medal.",
			],
			3: [
				"Real hands, {hero}! Good for the vine-lash AND for tending my very own garden.",
				"I remember being a person, a girl who wanted her own corner of the world. We were always people — a loud, tangled, loving bunch of them.",
				"Rotten, all I felt was squeezed, like the whole bunch was pressing in. Now I know I can stretch out and STILL be one of them when it counts.",
				"I'm taking a plot across the bog to build my own place. Welchie helped me pack — didn't guilt me once. We fight better knowing we CHOSE to stand together.",
			],
		},
	},

	# ── WATERMELON — Beach juice/gelato vendors (Auntie July's family) ──────
	"Watermelon": {
		"Wally": {   # cousin — forward-looking festival planner
			0: [
				"...the stand's... empty... crowds all... gone...",
				"...so hot... the heat... nobody left... to cool...",
			],
			1: [
				"Morning, {hero}. Squeezed a weak little jug today. But I'm dreaming up a festival. A real one. Someday.",
				"Auntie July keeps saying 'next summer.' I'm tired of waiting for next summer. I wanna MAKE this one count.",
				"Our chilled stand holds back the beach heat — keeps folks from wilting in the sun. When we drooped, the heat got brutal. Time to fix that.",
			],
			2: [
				"{hero}! Festival's ON. I'm inviting the whole island — even the mountain folk. Cousin Rindy's shipping gelato down to pair with our juice!",
				"Full-sugar batch today, ice-cold. The beach crowd's coming back and the heat's finally breaking. That's our job working!",
				"I painted the stand fresh. Bobby's got new recipes. We're not remembering good summers anymore — we're building one.",
			],
			3: [
				"Real hands, {hero}! Perfect for scooping and for shaking every festival-goer's hand!",
				"I remember now — we were beach vendors for generations, real people, the heart of every summer. We just got so lost in the old days we quit making new ones.",
				"When we were rotten, all I had was the memory of crowds. Ached like sunburn. Now the crowds are HERE, and I'm too busy scooping to be nostalgic.",
				"Rindy's coming down from Frostpeak for the festival — our two families, melon and gelato, cold treats against the heat. Auntie July's already crying. Happy crying.",
			],
		},
		"Bobby": {   # cousin — recipe tinkerer
			0: [
				"...I keep... squeezing... but it comes out... gray...",
				"...that old song... stuck in my head... won't... let go...",
			],
			1: [
				"Hey {hero}. Got a jug pressed this morning. Thin, but a start. Testing a new recipe too.",
				"I hum the old festival song without meaning to. Wally says it's sad. I say it's a promise.",
				"We keep the beach cool with juice and gelato — hold the heat back so folks don't wilt. Gotta get the stand humming again.",
			],
			2: [
				"{hero}! Three new recipes and they all WORK. Best batches since I was a little sprout!",
				"Wally's throwing a festival and I'm on flavors. Cousin Rindy up in Frostpeak sent her gelato base — melon-and-cream, it's UNREAL.",
				"The stand's chilling the whole boardwalk again. You can feel the heat back off when our ice starts flowing. That's the duty, {hero}.",
			],
			3: [
				"Real hands, {hero}! Way better for stirring the gelato churn!",
				"I remember being a person, a kid tasting Auntie July's first batch of the summer. We were always folks who made the heat bearable. Good work, if you ask me.",
				"Rotten, every flavor came out gray and flat, like the song in my head with no end. Now the flavors POP and the song's got a happy last verse.",
				"Rindy's bringing the mountain gelato down for the festival to pair with my melon juice. Two families, one cold treat, one hot beach. Been dreaming of this since I was knee-high.",
			],
		},
	},

	# ── CARROT — Frostpeak hunter-archer pass wardens (Fletch's family) ─────
	"Carrot": {
		"Scout": {   # nosy spotter kid with a spyglass
			0: [
				"...Pa locked... the door again... I just... wanted outside...",
				"...fog on the pass... can't see... nothin' through it...",
			],
			1: [
				"Hi {hero}! Pa let me play outside today! I only had to stay where he could see. Which is FAR, 'cause Pa sees everything.",
				"I got a spyglass! I spot for Pa when he's on the wall. I saw a snow-hare from a MILE off!",
				"We're peak wardens — we guard the mountain passes so nothin' bad sneaks through. Pa's the best archer ever. I'm his eyes.",
			],
			2: [
				"{hero}! I climbed a tree and Pa watched from BELOW and he didn't make me come down! Huge!",
				"I spotted a rockslide before it blocked the pass and hollered so Pa could ring the warning bell. We're a TEAM!",
				"Pa says I've got the sharpest eyes on the peak. Sharper than his! Well — he SAID it, so it's official.",
			],
			3: [
				"Look {hero}, real eyes AND real hands — now I can hold the spyglass AND a bow!",
				"Pa says we were always people, wardens of these passes for ages and ages. I don't remember but I believe him. We keep everybody safe up here!",
				"When I was the sad me, the fog got so thick I couldn't spot anything, and Pa wouldn't let me try. Now the fog's gone and Pa says GO LOOK. So I look at EVERYTHING.",
				"Pa's teaching me the bow, {hero}! For real! He said a warden's gotta see far AND aim true. I'm gonna guard these passes right beside him someday.",
			],
		},
	},
}

# GENERIC member fallback — keeps any un-written walker talkable.
const GENERIC_MEMBER: Dictionary = {
	0: [
		"...you're... one of the dream-walkers... aren't you...",
		"...can't... talk much... everything's... so heavy...",
	],
	1: [
		"Morning, {hero}. Still finding my feet, but it's easier with you around.",
		"The family's mending, little by little. You can see it, can't you?",
		"Thanks for stopping to talk. Not everyone bothers with us wanderers.",
	],
	2: [
		"{hero}! Good to see you out and about. The whole family's brighter these days.",
		"Feels good to be useful again — we've all got our part to play.",
		"Come by anytime. The door's always open now.",
	],
	3: [
		"Morning, {hero}! Human again — still getting used to saying that.",
		"We owe you more than we can say. Truly.",
		"The family's whole, thanks to you. Every one of us.",
		"Stop and chat anytime, {hero}. You're practically kin now.",
	],
}

const TIER_NAMES: Array = ["Rotten", "Wilted", "Ripe", "Restored"]

# ---------------------------------------------------------------------------
# GENERIC fallbacks — used whenever a family's pool is empty. Keeps every
# family talkable from day one while the real dialogue gets written.
# ---------------------------------------------------------------------------
const GENERIC: Dictionary = {
	0: {
		"daily":    ["...you... came...", "...so... heavy... everything..."],
		"story":    ["...we weren't... always... like this..."],
		"deposit":  ["...warm... that's... warm..."],
		"tier_up":  ["...I can... stand... thank you..."],
		"no_karma": ["...come back... when the dream... gives..."],
	},
	1: {
		"daily":    ["Oh — {hero}. It's a little easier to talk today.", "Still pale, I know. But upright."],
		"story":    ["I can almost remember how it started..."],
		"deposit":  ["I feel that. Truly. Thank you."],
		"tier_up":  ["The color... it's coming back, isn't it?"],
		"no_karma": ["Just seeing you helps. But the dream is where we mend."],
	},
	2: {
		"daily":    ["{hero}! Wonderful morning, isn't it?", "Business is picking up again, you know."],
		"story":    ["Now that my head is clear, I should tell you the truth about us..."],
		"deposit":  ["Ha! I feel ten seasons younger."],
		"tier_up":  ["Look at me — RIPE! I owe you everything."],
		"no_karma": ["No troubles today. Go on, enjoy the sun."],
	},
	3: {
		"daily":    ["Morning, {hero}. Tea's on if you have a minute.", "The whole family's been asking about you."],
		"story":    ["There's one last thing you deserve to know about us..."],
		"deposit":  ["You keep giving even now. We won't forget it."],
		"tier_up":  ["I'm... me again. Human. I had forgotten what that felt like."],
		"no_karma": ["Rest today, hero. You've earned it."],
	},
}

# ---------------------------------------------------------------------------
# ███ THE DIALOGUE — ADD ALL FAMILY LINES BELOW ███
# ---------------------------------------------------------------------------
const DIALOG: Dictionary = {

	# ── APPLE — the fully-written TEMPLATE (health / orchard / Granny) ──────
	"Apple": {
		0: {
			"daily": [
				"...apples... shouldn't... smell like this...",
				"...is it... morning...? hard to... tell...",
				"...the fire... won't catch... the mountain's... so cold now...",
			],
			"story": [
				"...the orchard... died first... then... us...",
				"...my son... won't look at me... he thinks... I'm already gone...",
				"...our warmth... used to hold... the frost back... now it just... creeps in...",
			],
			"deposit":  [
				"...oh... oh, that's... sweet... like the old harvest...",
				"...like a coal... in cold hands... thank you...",
			],
			"tier_up":  ["...the mold... it's lifting... I can smell blossom..."],
			"no_karma": [
				"...bring me... the dream's kindness... when you can...",
				"...just sit... by what's left... of the fire...",
			],
		},
		1: {
			"daily": [
				"Good morning, {hero}. I managed to bake today. Badly, but I baked.",
				"Blossom keeps fussing over me. Let him fuss — it keeps his hands busy.",
				"The hearth caught this morning. First real flame in weeks. The cold backed off a step.",
				"Cormac won't stop stoking the fire. As if warmth alone could keep me here. Bless him.",
			],
			"story": [
				"You've noticed my cough, I'm sure. In the waking world... it isn't the curse doing that, dear.",
				"The children don't know how sick I really am. Denial is a family recipe too.",
				"Our family kept Frostpeak warm for generations — cider, quilts, an open hearth. When we rotted, the blizzards came howling down. That's our failure out there in the snow.",
			],
			"deposit":  [
				"Warm as a windowsill pie. Thank you, dear.",
				"That settles into these old bones like a warm quilt. Bless you.",
			],
			"tier_up":  [
				"I stood up on my own this morning. First time in months.",
				"The frost on the window melted where I breathed. I'm still here, dear.",
			],
			"no_karma": [
				"No dream-gifts today? Then just sit with an old woman a moment.",
				"Empty-handed? No matter. Pull a chair to the fire and tell me the news.",
			],
		},
		2: {
			"daily": [
				"{hero}! Catch — a fresh one, off the new branch. Best crop in years.",
				"Pip climbed the big tree again. I pretended not to see.",
				"The whole household's knitting again — quilts for every cabin on the peak. Nobody freezes on our watch.",
				"Cormac laughed this morning, {hero}. A real laugh. I haven't heard that since before I took ill.",
				"Cider's on the boil. The miners trek up from the caverns for a mug. Word travels when a hearth's warm again.",
			],
			"story": [
				"Now that my mind is clear, I'll say it plainly: I am dying, dear. The curse only... paused it.",
				"My son grieves me while I'm still here. That's the rot we grew, long before the island's.",
				"Here's the ache of it: my whole family caught his mourning. Grieving the warmth while it's still burning right in front of them.",
			],
			"deposit":  [
				"Straight to the roots, that one. I felt it bloom.",
				"Warms me clear through, like the first cider of winter. Ha!",
			],
			"tier_up":  [
				"RIPE! Ha! Granny's got juice in her veins yet!",
				"RIPE, and the hearth's roaring! Let the blizzards try us now!",
			],
			"no_karma": [
				"Empty-handed and still visiting? You're a good one.",
				"Nothing to give? Then take — a quilt, a mug, a hug. That's what a hearth's for.",
			],
		},
		3: {
			"daily": [
				"Morning, dear. Human hands again — I'd forgotten how good kneading dough feels.",
				"The family's whole. Whatever time I have left, it's MINE now.",
				"Cormac finally sat and let me tell him the truth. We cried, then we baked. Human hands, {hero} — nothing warms a house like them.",
				"Blossom's learning my quilt-knots. Pip's stealing cider. The hearth's never been warmer.",
				"I sent spiced cider down to the beach melon folk, and word up to Rindy on the far peak — her gelato and my cider, warm and cold, both against the weather.",
				"Every morning I wake up human is a gift you gave me, dear. I don't waste a single one.",
			],
			"story": [
				"I've made peace with it, {hero}. Not cured — I never asked to be. Just... present. That's your real gift.",
				"We were people, {hero}. Always. Hearth-keepers of Frostpeak, generations deep. The curse just wrapped us in rot until we forgot the fire we were.",
				"When the rot took me, the cold felt like the end of everything. But warmth was never gone — it waited under the frost. Same as us.",
			],
			"deposit":  [
				"Even now you give. Come here — hugs are mandatory.",
				"Still stoking this old fire, are you? Come warm your hands, then.",
			],
			"tier_up":  [
				"Look at me. LOOK at me! I could cry — I AM crying.",
				"Human — truly human — real skin feeling the hearth's warmth again. Whatever time I have, it's warm, and it's MINE.",
			],
			"no_karma": [
				"Sit. Eat. That's an order from your elder.",
				"No errands today. Sit by the hearth. Let an old woman spoil you.",
			],
		},
	},

	# ── COCONUT — surfing couple, hard outside / soft inside ────────────────
	"Coconut": {
		0: {
			"daily": [
				"...hard... everything... hard...",
				"...the kids... can't hear... the waves anymore...",
				"...the big tide... came in wrong... nobody... broke it...",
			],
			"story": [
				"...we worked... double shifts... thought it was... for them...",
				"...Kai stopped... asking us... to play... that's when...",
				"...we were tide-breakers... but we let... the surf... run wild...",
			],
			"deposit":  [
				"...feels like... warm sand... under my feet...",
				"...that reaches... somewhere the shell... couldn't...",
			],
			"tier_up":  ["...I can... uncurl my fists... finally..."],
			"no_karma": [
				"...the tide... bring something... next time...",
				"...just stand... in the shallows... with me...",
			],
		},
		1: {
			"daily": [
				"Morning, {hero}. Still stiff, but I can crack a smile today.",
				"Kai brought me a shell this morning. I actually looked at it.",
				"Piña and I paddled out at dawn and broke the first swell together. Felt like the old days, before the walls went up.",
				"The beach was rough while we rotted — waves clawing the shore. We're a tide-breaker family. Time we acted like it again.",
			],
			"story": [
				"We built these walls — Gnarls and me. Tough outside so nothing gets in. But nothing got OUT either.",
				"The kids think we don't care. Truth is, we forgot how to show it.",
				"Our whole calling is riding the big tides so the beach stays safe. When we hid behind our own shells, the sea stopped listening to us.",
			],
			"deposit":  [
				"That warmth... it's cracking the shell. Good.",
				"Feel that reach right past the husk. Been a long time.",
			],
			"tier_up":  [
				"I hugged Shelly this morning. She cried. So did I.",
				"Uncurled my fists and reached for Piña's hand first. First time in years I didn't wait to be reached for.",
			],
			"no_karma": [
				"No gift today? It's alright. You being here says enough.",
				"Empty-handed's fine, {hero}. Sit on the log, watch the surf with an old surfer.",
			],
		},
		2: {
			"daily": [
				"{hero}! Gnarls is teaching Kai to surf again. You should see them out there.",
				"We closed the stand early today. Took the kids to the reef instead.",
				"Piña and I broke a monster swell this morning, side by side. The beach hasn't been this calm in seasons — that's OUR work.",
				"Shelly rode her first little wave. I caught her at the end. I was RIGHT there, {hero}.",
				"The tide obeys us again. Turns out the sea reads a family that's finally reading each other.",
			],
			"story": [
				"I'll say it plain: we hid behind work because being present meant being vulnerable. We were scared of our own kids needing us.",
				"Gnarls still flinches when Shelly reaches for his hand. But he doesn't pull away anymore.",
				"A tide-breaker who won't let anyone in can't ride WITH anyone either. We were the strongest surfers on the coast and the loneliest family on it.",
			],
			"deposit":  [
				"Warm right to the core. The shell's thinning — that's a GOOD thing.",
				"Sweet all the way in. Keep cracking this old husk, {hero}.",
			],
			"tier_up":  [
				"RIPE! Ha! Tough on the outside, sweet on the in — just like a real coconut should be!",
				"RIPE! And you know what? I let the kids see me cry doing it. Wouldn't have dreamed of that a season ago.",
			],
			"no_karma": [
				"Go ride a wave for us, {hero}. We're fine today.",
				"Nothing banked? Then just come watch Kai surf. Proudest sight on the beach.",
			],
		},
		3: {
			"daily": [
				"Morning, {hero}. Human hands again — Gnarls says they're softer. I told him that's the point.",
				"Family breakfast. Every single morning now. Non-negotiable.",
				"Piña and I break the dawn tide together, then walk home for pancakes. Warrior work and soft mornings. Turns out you get to have both.",
				"Kai wants to be a tide-breaker like his old man. I told him only if he promises to come home for breakfast. He promised.",
				"Shelly floats on the little waves now, laughing. That laugh does more for this beach than any wall I ever built.",
			],
			"story": [
				"We almost lost them, {hero}. Not to the curse — to ourselves. You gave us back the softness we were too proud to keep.",
				"We were people the whole time, {hero}. Beach folk, tide-breakers, mom and dad. The rot just made a hard shell of us till we forgot the soft part inside.",
				"When we were rotten the sea felt like an enemy, cold and crushing. Turns out the ocean was never the threat — the walls between us were.",
			],
			"deposit":  [
				"Still giving? Come here — group hug. Kai, Shelly, get over here!",
				"You keep pouring warmth into us. Careful, or we'll adopt you.",
			],
			"tier_up":  [
				"Human. Soft hands, full heart. I never want to be hard again.",
				"Human again — and I broke the morning tide with my kids cheering from the sand. Strong AND soft. That's the whole point of us.",
			],
			"no_karma": [
				"Rest day? Good. Go be soft somewhere. You've earned it.",
				"No dream-work today? Grab a board. Gnarls will teach you. On the house.",
			],
		},
	},

	# ── WATERMELON — juice-stand grand-family, wistful nostalgia ────────────
	"Watermelon": {
		0: {
			"daily": [
				"...remember... summer... the juice... used to flow...",
				"...Wally... won't stop... humming that old song...",
				"...so hot... the stand's cold... nothing... to cool the beach...",
			],
			"story": [
				"...the stand... was always full... back then... before the season... turned...",
				"...we kept... waiting... for the crowds... to come back... they never did...",
				"...our chilled juice... held back the heat... now the beach... just... bakes...",
			],
			"deposit":  [
				"...sweet... like the first... watermelon of summer...",
				"...cool... on a burning tongue... thank you...",
			],
			"tier_up":  ["...I can taste... the juice again... it's coming back..."],
			"no_karma": [
				"...maybe tomorrow... the season... will turn...",
				"...sit in the shade... of the empty stand... with me...",
			],
		},
		1: {
			"daily": [
				"Oh, {hero}. Bobby squeezed a whole jug this morning. Weak, but it's juice.",
				"I keep looking at the old festival photos. We used to fill the whole square.",
				"Cranked the ice churn again today. The boardwalk cooled a few degrees. That's our whole job — chilling the beach so folks don't wilt.",
				"Wally's got that festival gleam in her eye. I keep telling her 'next summer.' She keeps telling me 'why not THIS one.'",
			],
			"story": [
				"We were the heart of every summer festival on the island. People came from everywhere for our juice.",
				"When the crowds stopped coming, we just... kept setting up the stand. Every morning. For nobody.",
				"Our stand's meant to hold back the beach heat — a cold oasis in the blaze. When we wilted, the whole shore turned into a furnace. That was us failing.",
			],
			"deposit":  [
				"That's refreshing. Like a breeze off the water.",
				"Cool and sweet, right when I needed it. Bless you.",
			],
			"tier_up":  [
				"The color's coming back! Look at this rind — gorgeous!",
				"I hummed the festival song without it aching this time. Progress, dear.",
			],
			"no_karma": [
				"No worries, dear. Just having company is sweet enough.",
				"Nothing today? Sit in the shade of the stand. I'll fan you myself.",
			],
		},
		2: {
			"daily": [
				"{hero}! Try this — fresh squeezed, full sugar. Best batch in YEARS.",
				"Wally's planning a festival. A real one! Says she'll invite the whole island.",
				"The stand's chilling the whole boardwalk again. You can feel the heat step back when our ice starts flowing.",
				"Bobby's testing a melon-and-cream gelato with a base my niece Rindy sent down from Frostpeak. Two families, one cold treat!",
				"Crowds are trickling back, {hero}. Not a flood yet. But the line reached the pier this morning and I nearly wept.",
			],
			"story": [
				"I'll tell you what really rotted us, {hero}. We were so busy remembering the good old days that we forgot to make new ones.",
				"Auntie July kept saying 'next summer will be different.' Ten summers later, she was still saying it.",
				"A vendor who only serves memories has nothing cold left to pour. The heat crept in because we stopped making new sweetness.",
			],
			"deposit":  [
				"Juicy! I feel like a whole melon in the peak of August!",
				"Ice-cold and sugar-sweet! You've made my whole season, dear.",
			],
			"tier_up":  [
				"RIPE! The sweetest I've been in a decade! Summer's HERE, baby!",
				"RIPE! And this time I'm not waiting for the crowd — I'm ringing the bell and CALLING them!",
			],
			"no_karma": [
				"Go enjoy the sun, {hero}. Summer doesn't wait.",
				"Nothing banked? Then take a scoop and go cool off. On the house, always.",
			],
		},
		3: {
			"daily": [
				"Morning, {hero}! Human again — and you know what? The juice tastes even better with real hands.",
				"Bobby's got three new recipes. Wally's painted the stand. The cousins are fighting over who runs the scoops.",
				"The festival's set — the whole island's coming. Rindy's hauling her Frostpeak gelato down to pair with our melon juice. Cold treats against a hot beach, two families strong.",
				"Every stand on the boardwalk's cool again. Nobody wilts in the sun on OUR watch anymore.",
				"I catch myself humming that old song — but happy now. It's not a mourning tune anymore, it's an invitation.",
			],
			"story": [
				"We stopped waiting for the old summers to come back, {hero}. We're making our OWN season now. That's your gift to us.",
				"We were people all along, {hero} — beach vendors, generations of us, the heart of every summer. The rot just wrapped us in a longing for the past.",
				"Being rotten was all memory and no juice, aching like sunburn for crowds long gone. Turns out the sweetness was never behind us. We just had to squeeze it fresh.",
			],
			"deposit":  [
				"Sweet to the seed! You keep giving and we keep growing.",
				"You pour into us like sugar into juice. Permanent free scoop, that's the deal.",
			],
			"tier_up":  [
				"HUMAN! Look at these hands! I'm gonna squeeze every melon on this island!",
				"Human — and the festival's tomorrow! Real hands, real crowd, real summer. You gave us our season back, {hero}.",
			],
			"no_karma": [
				"Take a seat, have some juice. On the house — forever.",
				"No dream-errands today? Good. Come to the festival planning. We need a taste-tester.",
			],
		},
	},

	# ── BANANA — lone-parent former performer, stage fright ─────────────────
	"Banana": {
		0: {
			"daily": [
				"...the spotlight... I can still... feel it... burning...",
				"...Nanette keeps... singing... I can't... join in...",
				"...the jungle's... so quiet... no cheer left... in it...",
			],
			"story": [
				"...I used to... perform... before... they left...",
				"...the stage... it just... went dark... and I... couldn't...",
				"...we kept the jungle's spirits up... our whole troupe... now it just... rots in silence...",
			],
			"deposit":  [
				"...oh... applause... I remember... applause...",
				"...a warm light... on a dark stage... thank you...",
			],
			"tier_up":  ["...my voice... I found... a note..."],
			"no_karma": [
				"...the show... it needs... something... to go on...",
				"...sit in the empty seats... a while... with me...",
			],
		},
		1: {
			"daily": [
				"Hey, {hero}. Nanette learned a new song today. She gets it from me, I guess.",
				"I found my old costume in the closet. Couldn't put it on. But I didn't throw it away.",
				"Did a tiny soft-shoe for Nanette this morning. The jungle critters even peeked out to watch. Cheering folk up — that used to be our whole calling.",
				"When our troupe went dark, so did the jungle's mood. Sullen vines, grumpy beasts. Morale's a real job out here, {hero}.",
			],
			"story": [
				"My partner was the brave one. They'd pull me onstage every night. When they left... the music just stopped.",
				"Nanette doesn't know why I quit. She thinks I just got bored. Easier than the truth.",
				"We were the jungle's performers, {hero} — kept the whole canopy laughing. A performer who can't face the stage leaves everyone in the dark. That silence out there? That's mine.",
			],
			"deposit":  [
				"Like a warm spotlight. The good kind.",
				"That lands like the first clap in a quiet house. Thank you.",
			],
			"tier_up":  [
				"I hummed today, {hero}. First time in years. Nanette joined in.",
				"I put on the old costume. Just to look. Didn't cry. That's a curtain lifting.",
			],
			"no_karma": [
				"No dream-gifts? Then just sit and listen. Nanette's practicing.",
				"Empty-handed's fine. Take a front-row seat — the show's small, but it's back.",
			],
		},
		2: {
			"daily": [
				"{hero}! I sang for Nanette this morning. Her face... you should've seen it.",
				"I'm writing a new act. Nothing big. Just... something small, for the two of us.",
				"Did a full number in the clearing and the jungle came ALIVE — birds, beasts, the lot. That's the troupe's magic returning.",
				"Nanette insists we rehearse a duet. Terrifying. Wonderful. She's braver than I ever was.",
				"The whole jungle's cheerier since I found my voice. Morale-keeping really is a duty, {hero} — who knew a song could hold back the gloom.",
			],
			"story": [
				"The truth is, I wasn't just scared of the stage. I was scared Nanette would see me fail.",
				"My partner leaving broke something, but hiding from Nanette broke something worse. She deserved a parent who showed up.",
				"A troupe is meant to lift everyone's spirits — but I couldn't lift my own. I let the whole jungle go quiet rather than risk one shaky note.",
			],
			"deposit":  [
				"Encore! That felt like a standing ovation!",
				"Bravo! You've got a performer's timing, {hero} — always the perfect cue.",
			],
			"tier_up":  [
				"RIPE! I feel like opening night — butterflies and all! The GOOD butterflies!",
				"RIPE! And I took my bow WITHOUT looking for the wings to hide in. Growth!",
			],
			"no_karma": [
				"No gifts needed. I've got a song in my head and a kid in the front row.",
				"Nothing today? Then stay for the rehearsal. Nanette's picked our finale.",
			],
		},
		3: {
			"daily": [
				"Morning, {hero}! Human hands again — you know what that means? I can hold a microphone properly.",
				"Nanette and I are doing a duet at the festival. She picked the song. I'm terrified. I can't wait.",
				"The jungle's practically singing back these days. A cheerful troupe makes a cheerful canopy — that's the old family truth, and it's true again.",
				"I've started training a couple of young performers. Passing the spotlight on instead of hiding from it.",
			],
			"story": [
				"I'm done hiding backstage, {hero}. Not because I'm not scared — I AM. But Nanette's in the audience. That's enough.",
				"We were people, {hero} — a family of performers, generations of them, keeping this jungle's heart light. The rot just dragged the curtain shut on all of us.",
				"When I was rotten, the stage-lights felt like a memory of pain. But the music was never gone — it was waiting in the wings the whole time, like Nanette waiting for me to sing.",
			],
			"deposit":  [
				"A standing ovation from the universe itself. Thank you.",
				"You keep filling my house with light, {hero}. That's the best review a performer can get.",
			],
			"tier_up":  [
				"I'm ME again. The real me — not the one hiding in the wings.",
				"Human — and I sang the opening number to a full jungle, hands NOT shaking. Well. Barely shaking. That's a triumph!",
			],
			"no_karma": [
				"Go take a bow, {hero}. You've earned the spotlight today.",
				"No dream-work? Then be my audience. Nanette and I have a number to run.",
			],
		},
	},

	# ── BROCCOLI — burly father + twin sons, sibling rivalry ────────────────
	"Broccoli": {
		0: {
			"daily": [
				"...strong... gotta stay... strong...",
				"...the boys... they won't... stop fighting...",
				"...the beasts... broke loose... nobody... to wrangle 'em...",
			],
			"story": [
				"...Roman and Remy... used to spar... for fun... now it's... for real...",
				"...I pushed them... too hard... wanted them... tougher than me...",
				"...we kept the jungle beasts... in check... now they trample... whatever they want...",
			],
			"deposit":  [
				"...that strength... it's real... not the fake kind...",
				"...like iron... setting back... into brittle bone...",
			],
			"tier_up":  ["...standing tall... the stalk... holds..."],
			"no_karma": [
				"...come back... when you've got... the iron...",
				"...just spot me... on this next lift... will you...",
			],
		},
		1: {
			"daily": [
				"Morning, {hero}. Did fifty push-ups before dawn. Old habits.",
				"Roman asked Remy to spot him today. That's... new.",
				"Drove a stray beast back into the deep jungle this morning. Reminded me what we're FOR — keeping the big brutes in check so folks stay safe.",
				"The twins' racket used to shake the rafters. Quieter today. A GOOD quiet, for once.",
			],
			"story": [
				"I raised them to be strong. Strongest on the island. Problem is, I never taught them strong doesn't mean AGAINST each other.",
				"Remy thinks I favor Roman. Roman thinks Remy's soft. They're both wrong and they're both right.",
				"We're the jungle's beast-wardens, {hero} — strongmen who keep the rampaging things in line. When my boys turned their strength on each other, the beasts ran wild. That's on us.",
			],
			"deposit":  [
				"Solid as oak, that one. Felt it in my bones.",
				"That's real iron, {hero} — settling right back into my spine. Ha!",
			],
			"tier_up":  [
				"The boys trained together today. TOGETHER. I almost cried. Almost.",
				"Hauled a full-grown beast back to the deep jungle single-handed. The stalk holds strong again.",
			],
			"no_karma": [
				"No karma? Fine. Drop and give me twenty instead. Ha!",
				"Empty-handed's alright. Spot me on a lift, then. Company makes the iron lighter.",
			],
		},
		2: {
			"daily": [
				"{hero}! The boys sparred this morning — and they were LAUGHING. When's the last time THAT happened?",
				"Broc Lee bench-pressed a boulder today. The REAL kind, not the emotional kind.",
				"Roman and Remy herded a whole rampaging pack back into the wild TOGETHER. That's the job done right — brute work needs a team, not a rivalry.",
				"The jungle beasts stay to the deep paths now. That's the wardens' duty holding — strength that protects, not strength that shows off.",
				"Caught Roman coaching Remy's form instead of racing him. Fifteen years I waited to see that.",
			],
			"story": [
				"I made everything a competition because that's how MY father raised me. Win or you're nothing. What a stupid lesson to pass down.",
				"Roman and Remy don't need to beat each other. They need to carry each other. Took me losing everything to see it.",
				"A warden family only holds the beasts back if it holds TOGETHER. My boys pulling against each other let the whole jungle off its leash.",
			],
			"deposit":  [
				"POWER! That's the good stuff! Straight to the biceps!",
				"That surges through me like a fresh set! I could wrangle a whole herd, {hero}!",
			],
			"tier_up":  [
				"RIPE! Feel these arms! I could bench the whole dojo!",
				"RIPE! And the boys spotted me for the lift — all three of us strong, together. THAT'S the family I wanted.",
			],
			"no_karma": [
				"Go train, {hero}. Strength isn't just muscle — it's showing up.",
				"Nothing banked? Then join the drill. Roman and Remy will show you the ropes — together, mind you.",
			],
		},
		3: {
			"daily": [
				"Morning, {hero}. Human again — and I've still got the biggest arms on the island. Some things don't change.",
				"The boys are training a new kid at the dojo. Teaching, not competing. That's my legacy now.",
				"Roman and Remy ward the jungle passes as a pair now — no scoreboard, no rivalry. The beasts don't stand a chance against brothers in step.",
				"Real hands, real muscle, and finally the sense to know strength is for lifting others UP. Best lesson I ever learned late.",
			],
			"story": [
				"Strength was always the easy part, {hero}. You taught us the hard part — being strong enough to be gentle.",
				"We were people, {hero} — beast-wardens, trainers, a father and his twin boys. Generations of us kept this jungle safe. The rot just turned our strength inward until it curdled.",
				"When we were rotten, all I felt was what my boys couldn't out-lift in each other. Now I feel what we carry together. That's the strength that was under it the whole time.",
			],
			"deposit":  [
				"I'd flex in gratitude but I might break something. Thank you.",
				"You keep pouring iron into this old stalk, {hero}. The whole family stands taller for it.",
			],
			"tier_up":  [
				"HUMAN! These fists! These REAL fists! I'm never letting go again!",
				"Human — and my boys wrangled the morning beasts side by side while I watched, proud as a mountain. Strong AND together. That's everything.",
			],
			"no_karma": [
				"Take a rest day. Even the strongest need recovery.",
				"No dream-work? Then rest those muscles. Recovery's part of the strength, {hero}.",
			],
		},
	},

	# ── ONION — elderly widower, three generations, slow-burn grief ─────────
	"Onion": {
		0: {
			"daily": [
				"...tears... always... tears...",
				"...Lottie... Pearl... don't cry... for me...",
				"...the fog... creeps in... no one's brewing... the ward...",
			],
			"story": [
				"...she's been... gone so long... but the ache... never...",
				"...the children... they carry it too... my sadness... it seeps...",
				"...our remedies... warded the poison mist... now it just... rolls over the bog...",
			],
			"deposit":  [
				"...warm... she would have... liked the warmth...",
				"...that eases... one layer... gently... thank you...",
			],
			"tier_up":  ["...the tears... they're lighter... still there... but lighter..."],
			"no_karma": [
				"...come back... when the layers... peel away...",
				"...just sit... an old man... shouldn't grieve... alone...",
			],
		},
		1: {
			"daily": [
				"Ah, {hero}. I set two teacups out again this morning. Old habit. Forty years old.",
				"Pearl asked about her grandmother today. I managed three whole sentences before I stopped.",
				"Lottie brewed a batch of fog-ward tonic while I sat useless. The eastern paths cleared a little. That's our craft — keeping the poison mist at bay.",
				"My grief seeped into these walls so long the whole household breathes it. I'm trying to open a window, {hero}. Slowly.",
			],
			"story": [
				"She passed decades ago, {hero}. Decades. And I still reach for her hand in the night.",
				"The grief isn't the problem. Grief is natural. The problem is I let it fill every room in this house.",
				"We're the swamp's shaman-alchemists — our tonics ward the poison fog and mend the sick. When my heart clouded over, so did my brews, and the mist came rolling in.",
			],
			"deposit":  [
				"That peels away a layer. Gently. Thank you.",
				"Warm as a fresh pot of tea. It settles the ache a little, child.",
			],
			"tier_up":  [
				"I told Lottie a happy story about her grandmother today. A HAPPY one.",
				"I mixed a full ward-tonic without my hands shaking. The fog gave ground. So did my grief.",
			],
			"no_karma": [
				"No karma? Sit then. An old man shouldn't drink tea alone.",
				"Empty-handed's fine. Steep a cup with me. Company thins the fog better than any tonic.",
			],
		},
		2: {
			"daily": [
				"{hero}! Lottie cooked her grandmother's recipe last night. It tasted exactly right. I laughed instead of crying.",
				"Three generations in one house. Noisy, messy, alive. She would have loved it.",
				"The apothecary's fully stocked again. We're warding the whole eastern bog — travelers can breathe on those paths for the first time in years.",
				"Pearl's learning the herb songs her grandmother sang. I taught her every verse without my voice cracking. Well — hardly cracking.",
				"A fevered miner came up from the caverns and my tonic broke it by nightfall. THIS is what we're for — mending folk, warding the mist.",
			],
			"story": [
				"I kept this house a shrine to her memory. Everything preserved, nothing new allowed in. The children grew up tiptoeing around a ghost.",
				"Pearl told me she was afraid to be happy because it made me sad. A child should never carry that.",
				"An alchemist brews with a clear head, {hero}. Mine was drowned in old sorrow — no wonder the ward-tonics failed and the fog crept in. My grief was the poison, not the swamp.",
			],
			"deposit":  [
				"Layer by layer, it lifts. I can see clearly now.",
				"That clears the fog inside as much as out. Bless you, child.",
			],
			"tier_up":  [
				"RIPE! And do you know what? She'd have wanted this. All of it.",
				"RIPE! My tonics set true again and the eastern fog's in full retreat. Grief and poison, both giving ground!",
			],
			"no_karma": [
				"Go live loudly, {hero}. That's the best medicine for a quiet house.",
				"Nothing today? Then take a vial of ward-tonic for the road. The mist plays tricks near the bog.",
			],
		},
		3: {
			"daily": [
				"Morning, {hero}. Human again. These old bones creak, but they're MINE, and they're dancing.",
				"I put fresh flowers where her photo sits. Not funeral flowers — wildflowers. Pearl picked them.",
				"The whole swamp breathes easy now — our ward-tonics hold the poison fog clear from cottage to causeway. A healer's work, done right.",
				"Pearl gathers, Lottie brews, and I sing the old herb-songs over the pot. Three human generations in one apothecary. She'd have loved the noise.",
			],
			"story": [
				"I'll always love her, {hero}. But I love the living too. You taught this old onion that tears can water new roots.",
				"We were people, {hero} — swamp healers, generations deep, a family who kept the fog and the fevers at bay. The rot just wrapped my grief around all of us.",
				"When I was rotten, the sorrow felt bottomless, and my remedies curdled to match. But the healing was never gone — it waited under the grief, the way morning waits under the fog.",
			],
			"deposit":  [
				"Still peeling layers? At this rate I'll be transparent. Ha!",
				"You keep tending this old root, {hero}. New growth, even now. Thank you.",
			],
			"tier_up":  [
				"Human. Wrinkled, creaky, crying — but HUMAN. Thank you, child.",
				"Human again — and I brewed the morning's ward-tonic with Pearl at my elbow, both of us laughing. Loving the living AND the lost. That's the cure you gave me.",
			],
			"no_karma": [
				"Tea's ready. Sit. I've got stories — the happy kind, finally.",
				"No dream-errands? Then steep a pot with me. I've a hundred happy tales of her saved up.",
			],
		},
	},

	# ── GRAPE — matriarch + grown children in one big house, friction ───────
	"Grape": {
		0: {
			"daily": [
				"...too many... in this house... can't breathe...",
				"...Welchie and Mani... at it again... always...",
				"...the bog paths... choked with vine... nobody's cleared 'em...",
			],
			"story": [
				"...we're a bunch... stuck together... rotting from... the inside...",
				"...I kept them... all here... thought closeness... meant love...",
				"...the Vineguard... held the crossings open... now the swamp... swallows them...",
			],
			"deposit":  [
				"...sweet... the vine... remembers sweetness...",
				"...that loosens... the knot... a little... thank you...",
			],
			"tier_up":  ["...room to grow... that's what... we needed..."],
			"no_karma": [
				"...the vine... needs tending... come back...",
				"...pass through... let the old captain... catch her breath...",
			],
		},
		1: {
			"daily": [
				"Good morning, {hero}. Only one argument before breakfast today. That's progress.",
				"Welchie took a walk this morning. By himself. First time he didn't slam the door.",
				"The young ones cleared the north causeway at dawn — bickered the whole walk home, mind you, but moved like one blade in the field. That's the Vineguard blood.",
				"We're meant to keep the bog paths open, {hero}. When we tangled up at home, the whole swamp closed in. A warband can't guard trails it can't stop fighting over.",
			],
			"story": [
				"I thought if I kept everyone close, we'd stay strong. A bunch on the vine. But we were suffocating each other.",
				"Mani wants her own room. Welchie wants his own LIFE. And I keep pulling them back like they'll wither without me.",
				"We're the Vineguard — vine-lash fighters who keep the bog crossings clear. A bunch clenched too tight can't swing together. My grip on them let the trails go wild.",
			],
			"deposit":  [
				"That loosens the vine a little. Room to breathe.",
				"Sweet on the tongue, that. The old bunch remembers how to bloom.",
			],
			"tier_up":  [
				"Welchie and Mani had dinner together. By choice. Not because I made them.",
				"The squad ran a clean patrol and came home laughing. Room to grow — that's all we ever needed.",
			],
			"no_karma": [
				"No gifts? Then just pass through — a little outside air helps.",
				"Empty-handed's fine, soldier. Sit on the porch. Even a war-captain likes company.",
			],
		},
		2: {
			"daily": [
				"{hero}! Mani's started her own project — a little garden out back. I'm trying SO hard not to take over.",
				"The house is loud. But it's the good kind of loud now. Laughter, not arguments. Mostly.",
				"The Vineguard reopened the eastern causeway today — perfect formation, not one soldier out of step. The crossings are safe again because WE are.",
				"Welchie's drilling the young fighters now. Got his grandmother's footwork, that one. I couldn't be prouder.",
				"Merchants crossed the bog unharmed this morning and waved their thanks. THAT'S the whole point of a Vineguard — open roads, safe folk.",
			],
			"story": [
				"Here's what I didn't want to face: I wasn't holding us together out of love. I was scared of being alone.",
				"A bunch that can't let go of the vine never ripens. I had to learn to let them stretch.",
				"A warband fights as one but breathes as many. I tried to make us a single knotted fist — and a fist can't hold a spear OR a hand.",
			],
			"deposit":  [
				"Bursting with flavor! The whole bunch feels it!",
				"That surges down the whole vine, {hero} — every one of us stands a little taller.",
			],
			"tier_up":  [
				"RIPE! Every grape in this bunch — ripe and ready! You hear that, kids?!",
				"RIPE! And the squad moved like one weapon on patrol today — then squabbled over supper like the family we are. Perfect.",
			],
			"no_karma": [
				"Go stretch your own vine today, {hero}. We're good here.",
				"Nothing banked? Then walk the causeway with me. Safe as anything now — see for yourself.",
			],
		},
		3: {
			"daily": [
				"Morning, {hero}. Human again — and the house is STILL full. But now it's by choice.",
				"Welchie's got his own corner. Mani's got her garden. And Nonna Vitti? I've got a porch chair and my peace.",
				"The Vineguard patrols the bog as one blade and comes home as one loud, bickering, loving family. Both at once. That's the secret we lost and found.",
				"Mani's taking a plot across the water to build her own place. My old heart wanted to clutch her close — but a vine's stronger with room to climb. I let her go.",
			],
			"story": [
				"A real family isn't a bunch squeezed together, {hero}. It's vines that grow in their own direction but share the same root.",
				"We were people, {hero} — a warband, generations of the Vineguard, guarding these bogs shoulder to shoulder. The rot just squeezed us into one sour knot till we forgot we could stand apart AND together.",
				"When we were rotten, all I felt was the crowding, my whole bunch pressing in. Turns out we grow best reaching our own way — and swing hardest when we CHOOSE to swing together.",
			],
			"deposit":  [
				"You're family too at this point. Permanent seat at the table.",
				"Still feeding this old vine, are you? You've earned a place in the bunch, soldier.",
			],
			"tier_up":  [
				"Human! All of us! And we CHOSE to stay under one roof! That makes all the difference!",
				"Human — and the Vineguard rides again, by choice, not chains! Grown apart, standing together! THAT'S a warband. THAT'S a family, {hero}!",
			],
			"no_karma": [
				"Fresh juice is pressed, porch is warm. Sit or don't — you're welcome either way.",
				"No dream-work today? Then rest, soldier. Even the Vineguard stands down sometimes.",
			],
		},
	},

	# ── PEPPER — three hot-headed siblings, failing restaurant ──────────────
	"Pepper": {
		0: {
			"daily": [
				"...burning... everything... burns...",
				"...whose fault... WHOSE FAULT... was it...",
				"...the lava's creeping... nobody warding it... crews go hungry...",
			],
			"story": [
				"...the canteen... we burned it... ourselves... fighting over... the menu...",
				"...Rika says... my fault... Niño says... HER fault... Flambeau says... SHUT UP...",
				"...we warded the volcano... fed the miners... now the flow runs loose... and the bowls sit empty...",
			],
			"deposit":  [
				"...cool... that's... cool on the tongue... been so long...",
				"...it settles the fire... just enough... to breathe... thanks...",
			],
			"tier_up":  ["...the heat... it's settling... I can think... without rage..."],
			"no_karma": [
				"...bring something... before we... burn out...",
				"...just... let me simmer... a while... in quiet...",
			],
		},
		1: {
			"daily": [
				"Hey, {hero}. Rika only threw one pan this morning. Baby steps.",
				"Niño made a sauce today. Didn't ask anyone's opinion. Smart kid.",
				"Ladled out a dozen hot bowls to the mining crew before shift. First real service in ages. Feeding them's half our duty — the other half's keeping that lava in its channel.",
				"Steered the flow back from the east tunnels this morning. When we three fight, the mountain runs wild. We're wardens; we can't afford the feuding.",
			],
			"story": [
				"Three chefs, one kitchen, zero compromise. That's how you torch a canteen AND a family.",
				"We each blamed the other two. Easier than admitting we all threw fuel on the same fire.",
				"We're lava wardens who run the crew canteen — tame the volcano, feed the miners. When we turned the heat on each other, the flow ran loose and the crews went hungry. That's our failure, molten and plain.",
			],
			"deposit":  [
				"That cools the burn. Like water on a grease fire — wait, bad metaphor.",
				"Settles the heat right down. I can think straight for once. Thanks, {hero}.",
			],
			"tier_up":  [
				"Rika and Niño cooked side by side today. Nobody yelled. I'm shaking.",
				"Channeled the lava back into its bed clean and calm. The heat in me's settling too.",
			],
			"no_karma": [
				"No karma? Fine. I'll just... simmer. Ha. Get it?",
				"Empty-handed's alright. Pull up a stool at the canteen. First bowl's on me.",
			],
		},
		2: {
			"daily": [
				"{hero}! Taste this — all three of us made it TOGETHER. First time in years!",
				"Flambeau's writing a new menu. Asked Rika and Niño for IDEAS, not approval. Growth!",
				"The canteen served the whole night crew today — forty hot bowls, zero pans thrown. A fed miner digs deeper; that's our duty done right.",
				"Niño channeled the lava back by feel this morning. Kid's got a warden's gift. I told him so, out loud. His face!",
				"The flow's tame, the crews are fed, the mountain's steady. Turns out warding a volcano's easy once you stop erupting at each other.",
			],
			"story": [
				"We weren't fighting over food, {hero}. We were fighting over who mattered most. Three siblings who never learned they could ALL matter.",
				"The canteen failing wasn't the tragedy. The tragedy was using it as ammunition against each other.",
				"Lava wardens work as one or the mountain wins. Three of us pulling three ways let the flow loose and the crews starve. The fire outside was just the fire between us, made real.",
			],
			"deposit":  [
				"SPICY! That's the good heat! The 'we're alive' heat!",
				"Whoo! That lights me up the RIGHT way — cooking heat, not burning-down heat!",
			],
			"tier_up":  [
				"RIPE! Three peppers on one plant — and the plant is THRIVING!",
				"RIPE! Rika on grill, Niño on sauce, me calling the passes — one kitchen, three flames, no smoke!",
			],
			"no_karma": [
				"Kitchen's closed for the day. Go burn some calories, {hero}.",
				"Nothing banked? Then come eat. Warden's orders — nobody leaves this canteen hungry.",
			],
		},
		3: {
			"daily": [
				"Morning, {hero}! Human hands again — and they remember every recipe. Grand reopening is SOON.",
				"Rika's on grill, Niño's on sauce, Flambeau's on the floor. We finally figured out our stations.",
				"The canteen feeds every mining crew on the mountain now, hot and on time. And the lava? Runs where we tell it. Warden work AND kitchen work, both humming.",
				"Sent a pot of stew down to the Potato diggers this morning — Ida sent back a thank-you. Neighbors again, not just crews. Feels good.",
			],
			"story": [
				"Three siblings, one dream, zero ego. That's the new recipe, {hero}. You wrote it.",
				"We were people, {hero} — lava wardens and canteen cooks, generations of us feeding this mountain. The rot just turned our fire inward till we torched what we loved.",
				"When we were rotten, all I felt was blame with a name on it. Turns out the heat was never the enemy — it was ours to channel, into the flow and the food. Same as it always was.",
			],
			"deposit":  [
				"Chef's kiss! Mwah! That's going straight on the specials board!",
				"You keep stoking us the right way, {hero}. Careful — you'll get named a house regular.",
			],
			"tier_up":  [
				"HUMAN! The Pepper family is BACK! The canteen opens at sundown! You're eating FREE!",
				"Human — and the mountain's never run so smooth! Lava in its bed, crews in their seats, all three of us cooking as ONE. You did this, {hero}!",
			],
			"no_karma": [
				"Day off from the dream? Good. Come by the canteen tonight instead.",
				"No dream-work today? Then let us feed you. A warden always feeds their friends first.",
			],
		},
	},

	# ── POTATO — farmer couple + sons, stubborn pride, failing soil ─────────
	"Potato": {
		0: {
			"daily": [
				"...the soil... it gives... nothing...",
				"...Tot... Wedge... keep digging... don't stop...",
				"...the seams... all blighted... but we... handle our own...",
			],
			"story": [
				"...I won't... ask for help... we handle... our own...",
				"...the mine... it's dying... but a Potato... never quits...",
				"...we dug the gems... that fed the market... now the veins... just... crumble...",
			],
			"deposit":  [
				"...rain... that's like... rain on dry earth...",
				"...a little give... in the hard ground... thank you...",
			],
			"tier_up":  ["...something's... growing... I can feel... roots..."],
			"no_karma": [
				"...the soil... needs more... bring more...",
				"...walk the dark rows... with a stubborn old man...",
			],
		},
		1: {
			"daily": [
				"Morning, {hero}. Hands are sore but the hands are working. That's what matters.",
				"Tot found a green mineral yesterday. Just one. But it's real.",
				"Wedge shored up the deep tunnel before dawn. If we're gonna dig, we dig safe. We're miners — feeding the family and half the island besides.",
				"Ida keeps saying I should ask the neighbors how they beat the blight. Ida sees everything. Doesn't mean I'm ready to listen. Not yet.",
			],
			"story": [
				"The blight hit three seasons ago. I told no one. Russel doesn't ask for help — Russel GIVES help.",
				"The boys see me working dawn to dusk on dead seams. They think hard work fixes everything. I taught them that lie.",
				"We're the caverns' miners, {hero} — the gems and minerals we pull feed the whole island's trade. When the blight took the veins, my pride wouldn't let me say it. So the market went bare and my family went hungry.",
			],
			"deposit":  [
				"Good, honest nourishment. The soil thanks you.",
				"That soaks into the hard ground like the first rain of spring. Obliged, {hero}.",
			],
			"tier_up":  [
				"A whole seam came up glittering this morning. The mine lives.",
				"Let Wedge ask a neighbor a question and didn't bite his head off. Felt like a fresh vein opening.",
			],
			"no_karma": [
				"Nothing to haul? Then just walk the tunnels with me. Company helps.",
				"Empty-handed's fine. Sit a spell. Even a stubborn old digger likes a visitor.",
			],
		},
		2: {
			"daily": [
				"{hero}! Come look — three fresh veins! The mine hasn't glittered like this since before the blight!",
				"Wedge asked a neighbor how to drain the flooded shaft. I almost stopped him. Then I didn't.",
				"The Pepper canteen sends hot stew down the shaft for the crew now. Ida arranged it behind my back. A fed miner digs twice as deep — I can't even be cross about it.",
				"Tot's leading the south dig. My boy, calling his own crew. Never thought I'd hand over the pick. Proud I did.",
				"We're pulling enough ore to trade again — the market's got Potato gems on the tables. That's the family duty, back on its feet.",
			],
			"story": [
				"Here's the rot, {hero}: pride. Pure, stubborn, stupid pride. The veins were dying and I'd rather watch my family starve than say 'I need help.'",
				"Tot offered to learn the Broccoli family's hauling methods. I said no. Because if THEY could fix it and I couldn't, what am I?",
				"A miner who won't ask for a second lamp digs blind. My pride left the whole crew in the dark — Ida saw it all and just waited for me to catch up.",
			],
			"deposit":  [
				"Deep roots, that one! Straight to the bedrock!",
				"That reaches all the way down to the mother-seam! Much obliged, {hero}.",
			],
			"tier_up":  [
				"RIPE! The haul is BACK! Full carts, {hero}! FULL CARTS!",
				"RIPE! And I asked a neighbor for help WITHOUT choking on it. Ida nearly fainted. So did I!",
			],
			"no_karma": [
				"Shafts don't need working today. Go put your feet up.",
				"Nothing banked? Then rest. Even a Potato lets the pick lie idle sometimes — new lesson, that.",
			],
		},
		3: {
			"daily": [
				"Morning, {hero}. Human hands in real ore. Nothing better on this island.",
				"Tot and Wedge run the deep seams on their own now. I just... watch. And I'm proud.",
				"The mine feeds the market and the family both again — and I've finally got the sense to trade tips with the neighbors instead of digging alone. Ida was right. Ida's always right.",
				"Asked the Broccoli twins to teach my boys their hauling trick this week. Out loud, in front of everyone. Fifteen years too late, but I got there.",
			],
			"story": [
				"Asking for help isn't weakness, {hero}. It's opening a seam you can't dig alone. You taught this old miner that.",
				"We were people, {hero} — miners, generations of us, pulling the island's gems from the deep. The rot just hardened my pride into stone till it near buried us all.",
				"When we were rotten, all I knew was the next swing at dead rock — no past, no future, just gray labor and a pride I couldn't set down. Turns out the vein was always there. I just had to let someone hand me a lamp.",
			],
			"deposit":  [
				"Haul keeps on giving. Just like you.",
				"You keep working this old seam, {hero}. Careful — Ida'll set you a place at supper.",
			],
			"tier_up":  [
				"Human again. Calloused, ore-dust-under-the-nails human. Wouldn't have it any other way.",
				"Human — and I led the crew up from the deep with a neighbor's help and no shame in it. Strong hands AND an open one. That's the whole seam, {hero}.",
			],
			"no_karma": [
				"No work today? Good. Sit on the porch. Watch the carts roll in.",
				"No dream-errands? Then rest those hands. Ida'll have my hide if I put you to work.",
			],
		},
	},

	# ── CARROT — overprotective archer parent + nosy kid ────────────────────
	"Carrot": {
		0: {
			"daily": [
				"...stay close... Scout... don't wander...",
				"...the world... too dangerous... stay inside...",
				"...the passes... unguarded... anything could come through... anything...",
			],
			"story": [
				"...I see... everything... every threat... every shadow... I can't... stop watching...",
				"...Scout tried... to go outside... I locked... the door...",
				"...we warded the mountain passes... kept the peak safe... now the fog rolls in... unwatched...",
			],
			"deposit":  [
				"...sharp... I can see... a little further...",
				"...the fog lifts... just a hair... off my eyes... thank you...",
			],
			"tier_up":  ["...the fog... it's thinning... I can see... what's real..."],
			"no_karma": [
				"...keep watch... come back... with sharper eyes...",
				"...stand watch... at the window... with me... a while...",
			],
		},
		1: {
			"daily": [
				"Morning, {hero}. I counted every shadow between here and the gate. Only twelve. That's... manageable.",
				"Scout found a bug under a rock. Brought it to show me. I didn't scream. Progress.",
				"Walked the near pass at dawn and loosed a warning arrow at a rockslide before it blocked the trail. That's the duty — wardens keep these passes safe.",
				"Scout spotted the slide first, from the ridge, with that spyglass. Sharp eyes, that one. Sharper than I like to admit.",
			],
			"story": [
				"I was the best archer on the island once. Sharp eye, steady hand. Then Scout came along and suddenly everything looked like a threat.",
				"The world isn't more dangerous than it was. I just have more to lose. So I built walls.",
				"We're the peak wardens, {hero} — hunter-archers guarding the mountain passes. When I turned my sharp eye into a cage for Scout, I stopped watching the trails. The fog crept in where my aim used to be.",
			],
			"deposit":  [
				"Clear-eyed. I can see further today. Thank you.",
				"That sharpens the sight and steadies the hand both. Obliged, {hero}.",
			],
			"tier_up":  [
				"I let Scout play outside today. Watched from the window. Only checked six times.",
				"Loosed a clean shot down the pass and warded off a prowler. The aim's coming back — and so's my nerve.",
			],
			"no_karma": [
				"No gifts? Then go scout ahead. Tell me what you see. I trust your eyes.",
				"Empty-handed's fine. Take the ridge watch with me. Two sets of eyes guard a pass better than one.",
			],
		},
		2: {
			"daily": [
				"{hero}! Scout climbed a tree today. I watched from below. Didn't pull them down.",
				"Fletch hit a bullseye from sixty yards this morning. Still got it.",
				"Scout spotted a snow-cat on the high pass and I dropped a warning shot right at its feet. The two of us guard these trails like one archer with two pairs of eyes.",
				"Taught Scout to read the wind for a long shot today. A warden's got to see far AND aim true — and my kid's a natural.",
				"The passes are watched again, {hero}. Travelers cross the peak safe. That's the wardens' whole purpose, back in our hands.",
			],
			"story": [
				"I wasn't protecting Scout from the world, {hero}. I was protecting myself from the fear of losing them.",
				"An archer who sees threats in everything has perfect aim and zero peace. I was shooting at shadows.",
				"A warden's meant to watch the passes, not cage their own child. I aimed all my sharpness at Scout and left the real trails unguarded. The peak wasn't the danger. My fear was.",
			],
			"deposit":  [
				"Bullseye! Right to the heart!",
				"Dead center, {hero}! You've got a warden's aim — never miss the mark.",
			],
			"tier_up":  [
				"RIPE! Eyes sharp, heart steady, and Scout is running FREE!",
				"RIPE! And Scout spotted for me on the high pass today — a real warden pair. Proudest shot I ever made.",
			],
			"no_karma": [
				"Go explore, {hero}. And if Scout follows you — let them.",
				"Nothing banked? Then take the pass with Scout. Let the kid show you the lookouts.",
			],
		},
		3: {
			"daily": [
				"Morning, {hero}. Human eyes again — and you know what I see? My kid. Not the dangers around them. Just them.",
				"Scout wants to learn the bow. I said yes. I said YES, {hero}.",
				"Scout and I ward the passes together now — I aim, they spot. Two human wardens guarding the peak, exactly as our family has for generations.",
				"Real eyes, real hands, and the good sense to point them outward at the trails instead of inward at my own kid. That's the shot I finally landed.",
			],
			"story": [
				"The sharpest eye on the island, and I couldn't see what was right in front of me: a brave kid who just needed room to grow.",
				"We were people, {hero} — hunter-archers, peak wardens, generations of us guarding these passes. The rot just sharpened my fear into a cage and called it protection.",
				"When I was rotten, the fog was so thick I saw threats in every shadow and wouldn't let Scout near a one of them. But the clear sight was always there, under the fear — same as the kid I love was always right beside me.",
			],
			"deposit":  [
				"A gift that hits the mark. Every time.",
				"Straight to the gold, {hero}. You keep me and mine well-aimed.",
			],
			"tier_up":  [
				"Human. Every sense sharp. And for the first time, I'm not afraid of what I see.",
				"Human — and Scout stood the morning watch at my side, spyglass up, grinning. A warden family whole again. You gave me that, {hero}.",
			],
			"no_karma": [
				"Go wander, {hero}. The world's worth seeing. Tell Scout I said so.",
				"No dream-work today? Then rest your eyes. Even a warden lowers the bow sometimes.",
			],
		},
	},

	# ── APPLE done above; families end. Dragon Fruit (Carnival) arrives with
	#    the Carnival grounds build — add an entry here when they do. ────────
}

# ---------------------------------------------------------------------------
# Fetch helpers — scenes call these; they handle rotation + fallbacks.
# ---------------------------------------------------------------------------

static func elder_name(fam: String) -> String:
	return String(ELDERS.get(fam, fam + " Elder"))


static func wanderer_names(fam: String) -> Array:
	return WANDERERS.get(fam, [])


static func tier_name(tier: int) -> String:
	return TIER_NAMES[clampi(tier, 0, 3)]


# Pool with fallback: family's pool if non-empty, else the GENERIC tier pool.
static func _pool(fam: String, tier: int, key: String) -> Array:
	var t: int = clampi(tier, 0, 3)
	var fam_tiers: Dictionary = DIALOG.get(fam, {})
	var pools: Dictionary = fam_tiers.get(t, {})
	var arr: Array = pools.get(key, [])
	if arr.is_empty():
		arr = (GENERIC[t] as Dictionary).get(key, ["..."])
	return arr


static func _fill(line: String, hero: String) -> String:
	return line.replace("{hero}", hero)


# Daily small talk — rotates through the pool by visit count.
static func daily_line(fam: String, tier: int, visit_idx: int, hero: String = "") -> String:
	var arr: Array = _pool(fam, tier, "daily")
	return _fill(String(arr[visit_idx % arr.size()]), hero)


# Story layer — plays in order, clamps to the final written layer.
static func story_line(fam: String, tier: int, layer_idx: int, hero: String = "") -> String:
	var arr: Array = _pool(fam, tier, "story")
	return _fill(String(arr[clampi(layer_idx, 0, arr.size() - 1)]), hero)


# Random pick from a reaction pool ("deposit" / "tier_up" / "no_karma").
static func reaction_line(fam: String, tier: int, key: String, hero: String = "") -> String:
	var arr: Array = _pool(fam, tier, key)
	return _fill(String(arr[randi() % arr.size()]), hero)


# Wanderer (non-elder member) line — rotates by visit count, falls back to the
# GENERIC_MEMBER pool for any member/tier not written yet.
static func member_line(fam: String, who: String, tier: int, visit_idx: int, hero: String = "") -> String:
	var t: int = clampi(tier, 0, 3)
	var fam_members: Dictionary = MEMBER_DIALOG.get(fam, {})
	var tiers: Dictionary = fam_members.get(who, {})
	var arr: Array = tiers.get(t, [])
	if arr.is_empty():
		arr = (GENERIC_MEMBER[t] as Array)
	return _fill(String(arr[visit_idx % arr.size()]), hero)
