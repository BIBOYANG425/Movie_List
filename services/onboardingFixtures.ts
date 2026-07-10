/**
 * Curated onboarding suggestion pool for ANONYMOUS (signed-out) users.
 *
 * Why this exists: the web bundle no longer ships a TMDB key (Task 3 migration).
 * Every live TMDB seam — the `suggestions` edge function and `search/*` via the
 * `tmdb-proxy` — is authenticated, so a signed-out caller gets a 401 and empty
 * results. That dead-ended the anonymous signup funnel: LandingPage's "Get
 * Started" routes signed-out users to /onboarding/movies, where they must pick
 * ≥10 movies before the "Create your account" CTA appears, but the suggestion
 * grid and search both came back empty. This static pool restores the
 * try-before-signup flow: MovieOnboardingPage draws its suggestion grid from
 * here when there is no session, so a new user can pick 10 recognizable movies
 * and reach the account-creation step without ever calling the network.
 *
 * Shape mirrors exactly what MovieOnboardingPage renders (a subset of
 * TMDBMovie): id `tmdb_{n}`, tmdbId, title, year, posterUrl, genres, overview.
 * Posters are real TMDB poster paths served from the keyless image.tmdb.org
 * CDN (TMDB_IMAGE_BASE), so they resolve for signed-out users with no key.
 *
 * Signed-in behavior is untouched — authenticated users still get the live
 * 5-pool suggestions engine. This pool is the signed-out fallback only.
 *
 * Curation: ~48 broadly recognizable movies spread across decades (1970s–2020s)
 * and genres (drama, sci-fi, animation, action, crime, fantasy, romance). The
 * point of onboarding is "pick 10 you know," so mainstream recognizability beats
 * critical obscurity.
 *
 * Header last reviewed: 2026-07-10
 */

import type { TMDBMovie } from './tmdbService';
import { TMDB_IMAGE_BASE } from './tmdbService';

/**
 * A curated onboarding suggestion. A structural subset of TMDBMovie carrying
 * only the fields the onboarding grid + tier modal read. `toTMDBMovie` widens
 * it to a full TMDBMovie (type: 'movie', backdropUrl: null) at the consumption
 * seam so downstream code sees the identical shape as a live suggestion.
 */
export interface OnboardingFixtureMovie {
  id: string;
  tmdbId: number;
  title: string;
  year: string;
  posterUrl: string;
  genres: string[];
  overview: string;
}

/**
 * The static pool. Curated, authoritative TMDB metadata (title/year/genres/
 * poster path fetched from TMDB at build time). Insertion order is stable; the
 * page shuffles a copy per session so the grid is not identical every load.
 */
export const ONBOARDING_FIXTURE_MOVIES: OnboardingFixtureMovie[] = [
  {
    id: 'tmdb_238',
    tmdbId: 238,
    title: 'The Godfather',
    year: '1972',
    posterUrl: `${TMDB_IMAGE_BASE}/3bhkrj58Vtu7enYsRolD1fZdja1.jpg`,
    genres: ['Drama', 'Crime'],
    overview: 'Spanning the years 1945 to 1955, a chronicle of the fictional Italian-American Corleone crime family. When organized crime family patriarch, Vito Corleone barely survives an…',
  },
  {
    id: 'tmdb_155',
    tmdbId: 155,
    title: 'The Dark Knight',
    year: '2008',
    posterUrl: `${TMDB_IMAGE_BASE}/qJ2tW6WMUDux911r6m7haRef0WH.jpg`,
    genres: ['Action', 'Crime', 'Thriller'],
    overview: 'Batman raises the stakes in his war on crime. With the help of Lt. Jim Gordon and District Attorney Harvey Dent, Batman sets out to dismantle the remaining criminal organizations…',
  },
  {
    id: 'tmdb_680',
    tmdbId: 680,
    title: 'Pulp Fiction',
    year: '1994',
    posterUrl: `${TMDB_IMAGE_BASE}/vQWk5YBFWF4bZaofAbv0tShwBvQ.jpg`,
    genres: ['Thriller', 'Crime', 'Comedy'],
    overview: 'A burger-loving hit man, his philosophical partner, a drug-addled gangster\'s moll and a washed-up boxer converge in this sprawling, comedic crime caper. Their adventures unfurl in…',
  },
  {
    id: 'tmdb_550',
    tmdbId: 550,
    title: 'Fight Club',
    year: '1999',
    posterUrl: `${TMDB_IMAGE_BASE}/jSziioSwPVrOy9Yow3XhWIBDjq1.jpg`,
    genres: ['Drama', 'Thriller'],
    overview: 'A ticking-time-bomb insomniac and a slippery soap salesman channel primal male aggression into a shocking new form of therapy. Their concept catches on, with underground "fight…',
  },
  {
    id: 'tmdb_13',
    tmdbId: 13,
    title: 'Forrest Gump',
    year: '1994',
    posterUrl: `${TMDB_IMAGE_BASE}/Cw4hIUIAmSYfK9QfaUW5igp9La.jpg`,
    genres: ['Comedy', 'Drama', 'Romance'],
    overview: 'A man with a low IQ has accomplished great things in his life and been present during significant historic events—in each case, far exceeding what anyone imagined he could do. But…',
  },
  {
    id: 'tmdb_27205',
    tmdbId: 27205,
    title: 'Inception',
    year: '2010',
    posterUrl: `${TMDB_IMAGE_BASE}/xlaY2zyzMfkhk0HSC5VUwzoZPU1.jpg`,
    genres: ['Action', 'Sci-Fi', 'Adventure'],
    overview: 'Cobb, a skilled thief who commits corporate espionage by infiltrating the subconscious of his targets is offered a chance to regain his old life as payment for a task considered…',
  },
  {
    id: 'tmdb_157336',
    tmdbId: 157336,
    title: 'Interstellar',
    year: '2014',
    posterUrl: `${TMDB_IMAGE_BASE}/yQvGrMoipbRoddT0ZR8tPoR7NfX.jpg`,
    genres: ['Adventure', 'Drama', 'Sci-Fi'],
    overview: 'The adventures of a group of explorers who make use of a newly discovered wormhole to surpass the limitations on human space travel and conquer the vast distances involved in an…',
  },
  {
    id: 'tmdb_597',
    tmdbId: 597,
    title: 'Titanic',
    year: '1997',
    posterUrl: `${TMDB_IMAGE_BASE}/9xjZS2rlVxm8SFx8kPC3aIGCOYQ.jpg`,
    genres: ['Drama', 'Romance'],
    overview: '101-year-old Rose DeWitt Bukater tells the story of her life aboard the Titanic, 84 years later. A young Rose boards the ship with her mother and fiancé. Meanwhile, Jack Dawson…',
  },
  {
    id: 'tmdb_424',
    tmdbId: 424,
    title: 'Schindler\'s List',
    year: '1993',
    posterUrl: `${TMDB_IMAGE_BASE}/sF1U4EUQS8YHUYjNl3pMGNIQyr0.jpg`,
    genres: ['Drama', 'History', 'War'],
    overview: 'The true story of how businessman Oskar Schindler saved over a thousand Jewish lives from the Nazis while they worked as slaves in his factory during World War II.',
  },
  {
    id: 'tmdb_578',
    tmdbId: 578,
    title: 'Jaws',
    year: '1975',
    posterUrl: `${TMDB_IMAGE_BASE}/lxM6kqilAdpdhqUl2biYp5frUxE.jpg`,
    genres: ['Horror', 'Thriller', 'Adventure'],
    overview: 'When the seaside community of Amity finds itself under attack by a dangerous great white shark, the town\'s chief of police, a young marine biologist, and a grizzled shark hunter…',
  },
  {
    id: 'tmdb_105',
    tmdbId: 105,
    title: 'Back to the Future',
    year: '1985',
    posterUrl: `${TMDB_IMAGE_BASE}/vN5B5WgYscRGcQpVhHl6p9DDTP0.jpg`,
    genres: ['Adventure', 'Comedy', 'Sci-Fi'],
    overview: 'Eighties teenager Marty McFly is accidentally sent back in time to 1955, inadvertently disrupting his parents\' first meeting and attracting his mother\'s romantic interest. Marty…',
  },
  {
    id: 'tmdb_601',
    tmdbId: 601,
    title: 'E.T. the Extra-Terrestrial',
    year: '1982',
    posterUrl: `${TMDB_IMAGE_BASE}/an0nD6uq6byfxXCfk6lQBzdL2J1.jpg`,
    genres: ['Adventure', 'Sci-Fi', 'Family'],
    overview: 'An alien is left behind on Earth and saved by the 10-year-old Elliott who decides to keep him hidden in his home. While a task force hunts for the extra-terrestrial, Elliott, his…',
  },
  {
    id: 'tmdb_120',
    tmdbId: 120,
    title: 'The Lord of the Rings: The Fellowship of the Ring',
    year: '2001',
    posterUrl: `${TMDB_IMAGE_BASE}/6oom5QYQ2yQTMJIbnvbkBL9cHo6.jpg`,
    genres: ['Adventure', 'Fantasy', 'Action'],
    overview: 'Young hobbit Frodo Baggins, after inheriting a mysterious ring from his uncle Bilbo, must leave his home in order to keep it from falling into the hands of its evil creator. Along…',
  },
  {
    id: 'tmdb_122',
    tmdbId: 122,
    title: 'The Lord of the Rings: The Return of the King',
    year: '2003',
    posterUrl: `${TMDB_IMAGE_BASE}/rCzpDGLbOoPwLjy3OAm5NUPOTrC.jpg`,
    genres: ['Adventure', 'Fantasy', 'Action'],
    overview: 'As armies mass for a final battle that will decide the fate of the world--and powerful, ancient forces of Light and Dark compete to determine the outcome--one member of the…',
  },
  {
    id: 'tmdb_78',
    tmdbId: 78,
    title: 'Blade Runner',
    year: '1982',
    posterUrl: `${TMDB_IMAGE_BASE}/63N9uy8nd9j7Eog2axPQ8lbr3Wj.jpg`,
    genres: ['Sci-Fi', 'Drama', 'Thriller'],
    overview: 'In the smog-choked dystopian Los Angeles of 2019, blade runner Rick Deckard is called out of retirement to terminate a quartet of replicants who have escaped to Earth seeking…',
  },
  {
    id: 'tmdb_218',
    tmdbId: 218,
    title: 'The Terminator',
    year: '1984',
    posterUrl: `${TMDB_IMAGE_BASE}/qvktm0BHcnmDpul4Hz01GIazWPr.jpg`,
    genres: ['Action', 'Thriller', 'Sci-Fi'],
    overview: 'In the post-apocalyptic future, reigning tyrannical supercomputers teleport a cyborg assassin known as the "Terminator" back to 1984 to kill Sarah Connor, whose unborn son is…',
  },
  {
    id: 'tmdb_562',
    tmdbId: 562,
    title: 'Die Hard',
    year: '1988',
    posterUrl: `${TMDB_IMAGE_BASE}/7Bjd8kfmDSOzpmhySpEhkUyK2oH.jpg`,
    genres: ['Action', 'Thriller'],
    overview: 'High above the city of L.A. a team of terrorists has seized a building, taken hostages, and declared war. One man has manages to escape... An off-duty cop hiding somewhere inside.…',
  },
  {
    id: 'tmdb_85',
    tmdbId: 85,
    title: 'Raiders of the Lost Ark',
    year: '1981',
    posterUrl: `${TMDB_IMAGE_BASE}/ceG9VzoRAVGwivFU403Wc3AHRys.jpg`,
    genres: ['Adventure', 'Action'],
    overview: 'When Dr. Indiana Jones – the tweed-suited professor who just happens to be a celebrated archaeologist – is hired by the government to locate the legendary Ark of the Covenant, he…',
  },
  {
    id: 'tmdb_11',
    tmdbId: 11,
    title: 'Star Wars',
    year: '1977',
    posterUrl: `${TMDB_IMAGE_BASE}/6FfCtAuVAW8XJjZ7eWeLibRLWTw.jpg`,
    genres: ['Adventure', 'Action', 'Sci-Fi'],
    overview: 'Princess Leia is captured and held hostage by the evil Imperial forces in their effort to take over the galactic Empire. Venturesome Luke Skywalker and dashing captain Han Solo…',
  },
  {
    id: 'tmdb_1891',
    tmdbId: 1891,
    title: 'The Empire Strikes Back',
    year: '1980',
    posterUrl: `${TMDB_IMAGE_BASE}/nNAeTmF4CtdSgMDplXTDPOpYzsX.jpg`,
    genres: ['Adventure', 'Action', 'Sci-Fi'],
    overview: 'The epic saga continues as Luke Skywalker, in hopes of defeating the evil Galactic Empire, learns the ways of the Jedi from aging master Yoda. But Darth Vader is more determined…',
  },
  {
    id: 'tmdb_1892',
    tmdbId: 1892,
    title: 'Return of the Jedi',
    year: '1983',
    posterUrl: `${TMDB_IMAGE_BASE}/jQYlydvHm3kUix1f8prMucrplhm.jpg`,
    genres: ['Adventure', 'Action', 'Sci-Fi'],
    overview: 'Luke Skywalker leads a mission to rescue his friend Han Solo from the clutches of Jabba the Hutt, the Emperor prepares to crush the Rebellion with a more powerful Death Star, and…',
  },
  {
    id: 'tmdb_862',
    tmdbId: 862,
    title: 'Toy Story',
    year: '1995',
    posterUrl: `${TMDB_IMAGE_BASE}/uXDfjJbdP4ijW5hWSBrPrlKpxab.jpg`,
    genres: ['Family', 'Comedy', 'Animation'],
    overview: 'Led by Woody, Andy\'s toys live happily in his room until Andy\'s birthday brings Buzz Lightyear onto the scene. Afraid of losing his place in Andy\'s heart, Woody plots against…',
  },
  {
    id: 'tmdb_863',
    tmdbId: 863,
    title: 'Toy Story 2',
    year: '1999',
    posterUrl: `${TMDB_IMAGE_BASE}/4rbcp3ng8n1MKHjpeqW0L7Fnpzz.jpg`,
    genres: ['Animation', 'Comedy', 'Family'],
    overview: 'Andy heads off to Cowboy Camp, leaving his toys to their own devices. Things shift into high gear when an obsessive toy collector named Al McWhiggen, owner of Al\'s Toy Barn…',
  },
  {
    id: 'tmdb_585',
    tmdbId: 585,
    title: 'Monsters, Inc.',
    year: '2001',
    posterUrl: `${TMDB_IMAGE_BASE}/wFSpyMsp7H0ttERbxY7Trlv8xry.jpg`,
    genres: ['Animation', 'Comedy', 'Family'],
    overview: 'Lovable Sulley and his wisecracking sidekick Mike Wazowski are the top scare team at Monsters, Inc., the scream-processing factory in Monstropolis. When a little girl named Boo…',
  },
  {
    id: 'tmdb_12',
    tmdbId: 12,
    title: 'Finding Nemo',
    year: '2003',
    posterUrl: `${TMDB_IMAGE_BASE}/5lc6nQc0VhWFYFbNv016xze8Jvy.jpg`,
    genres: ['Animation', 'Family', 'Adventure'],
    overview: 'Nemo, an adventurous young clownfish, is unexpectedly taken from his Great Barrier Reef home to a dentist\'s office aquarium. It\'s up to his worrisome father Marlin and a friendly…',
  },
  {
    id: 'tmdb_809',
    tmdbId: 809,
    title: 'Shrek 2',
    year: '2004',
    posterUrl: `${TMDB_IMAGE_BASE}/2yYP0PQjG8zVqturh1BAqu2Tixl.jpg`,
    genres: ['Animation', 'Comedy', 'Family'],
    overview: 'Happily ever after never seemed so far far away when a trip to meet the in-laws turns into a hilariously twisted adventure for Shrek and Fiona. With the help of ever-faithful…',
  },
  {
    id: 'tmdb_920',
    tmdbId: 920,
    title: 'Cars',
    year: '2006',
    posterUrl: `${TMDB_IMAGE_BASE}/oloVyeBbkVGbFFaUjR8I7Boo7wA.jpg`,
    genres: ['Animation', 'Adventure', 'Comedy'],
    overview: 'Lightning McQueen, a hotshot rookie race car driven to succeed, discovers that life is about the journey, not the finish line, when he finds himself unexpectedly detoured in the…',
  },
  {
    id: 'tmdb_508442',
    tmdbId: 508442,
    title: 'Soul',
    year: '2020',
    posterUrl: `${TMDB_IMAGE_BASE}/6jmppcaubzLF8wkXM36ganVISCo.jpg`,
    genres: ['Animation', 'Family', 'Drama'],
    overview: 'Joe Gardner is a middle school teacher with a love for jazz music. After a successful audition at the Half Note Club, he suddenly gets into an accident that separates his soul…',
  },
  {
    id: 'tmdb_8587',
    tmdbId: 8587,
    title: 'The Lion King',
    year: '1994',
    posterUrl: `${TMDB_IMAGE_BASE}/sKCr78MXSLixwmZ8DyJLrpMsd15.jpg`,
    genres: ['Animation', 'Family', 'Drama'],
    overview: 'Young lion prince Simba, eager to one day become king of the Pride Lands, grows up under the watchful eye of his father Mufasa; all the while his villainous uncle Scar conspires…',
  },
  {
    id: 'tmdb_10681',
    tmdbId: 10681,
    title: 'WALL·E',
    year: '2008',
    posterUrl: `${TMDB_IMAGE_BASE}/hbhFnRzzg6ZDmm8YAmxBnQpQIPh.jpg`,
    genres: ['Animation', 'Family', 'Sci-Fi'],
    overview: 'After hundreds of years doing what he was built for, WALL•E— a robot designed to clean up the earth—discovers a new purpose in life when he meets a sleek search robot named EVE.…',
  },
  {
    id: 'tmdb_129',
    tmdbId: 129,
    title: 'Spirited Away',
    year: '2001',
    posterUrl: `${TMDB_IMAGE_BASE}/39wmItIWsg5sZMyRUHLkWBcuVCM.jpg`,
    genres: ['Animation', 'Family', 'Fantasy'],
    overview: 'A young girl, Chihiro, becomes trapped in a strange new world of spirits. When her parents undergo a mysterious transformation, she must call upon the courage she never knew she…',
  },
  {
    id: 'tmdb_674',
    tmdbId: 674,
    title: 'Harry Potter and the Goblet of Fire',
    year: '2005',
    posterUrl: `${TMDB_IMAGE_BASE}/fECBtHlr0RB3foNHDiCBXeg9Bv9.jpg`,
    genres: ['Adventure', 'Fantasy'],
    overview: 'When his name emerges from the Goblet of Fire, Harry Potter becomes a competitor in a grueling battle for glory among three wizarding schools. Signs of Voldemort\'s return emerge…',
  },
  {
    id: 'tmdb_671',
    tmdbId: 671,
    title: 'Harry Potter and the Philosopher\'s Stone',
    year: '2001',
    posterUrl: `${TMDB_IMAGE_BASE}/wuMc08IPKEatf9rnMNXvIDxqP4W.jpg`,
    genres: ['Adventure', 'Fantasy'],
    overview: 'Harry Potter has lived under the stairs at his aunt and uncle\'s house his whole life. But on his 11th birthday, he learns he\'s a powerful wizard—with a place waiting for him at…',
  },
  {
    id: 'tmdb_767',
    tmdbId: 767,
    title: 'Harry Potter and the Half-Blood Prince',
    year: '2009',
    posterUrl: `${TMDB_IMAGE_BASE}/z7uo9zmQdQwU5ZJHFpv2Upl30i1.jpg`,
    genres: ['Adventure', 'Fantasy'],
    overview: 'Dumbledore tries to prepare Harry for the final battle with Voldemort while Death Eaters wreak havoc in both Muggle and Wizard worlds.',
  },
  {
    id: 'tmdb_12445',
    tmdbId: 12445,
    title: 'Harry Potter and the Deathly Hallows: Part 2',
    year: '2011',
    posterUrl: `${TMDB_IMAGE_BASE}/c54HpQmuwXjHq2C9wmoACjxoom3.jpg`,
    genres: ['Adventure', 'Fantasy'],
    overview: 'Harry, Ron and Hermione continue their quest to vanquish the evil Voldemort once and for all. Just as things begin to look hopeless for the young wizards, Harry discovers a trio…',
  },
  {
    id: 'tmdb_620',
    tmdbId: 620,
    title: 'Ghostbusters',
    year: '1984',
    posterUrl: `${TMDB_IMAGE_BASE}/7E8nLijS9AwwUEPu2oFYOVKhdFA.jpg`,
    genres: ['Comedy', 'Fantasy'],
    overview: 'After losing their university jobs, three parapsychologists start a ghost-catching business in New York City and uncover a supernatural threat that could destroy the world.',
  },
  {
    id: 'tmdb_244786',
    tmdbId: 244786,
    title: 'Whiplash',
    year: '2014',
    posterUrl: `${TMDB_IMAGE_BASE}/7fn624j5lj3xTme2SgiLCeuedmO.jpg`,
    genres: ['Drama', 'Music', 'Thriller'],
    overview: 'Under the direction of a ruthless instructor, a talented young drummer begins to pursue perfection at any cost, even his humanity.',
  },
  {
    id: 'tmdb_194662',
    tmdbId: 194662,
    title: 'Birdman or (The Unexpected Virtue of Ignorance)',
    year: '2014',
    posterUrl: `${TMDB_IMAGE_BASE}/rHUg2AuIuLSIYMYFgavVwqt1jtc.jpg`,
    genres: ['Drama', 'Comedy'],
    overview: 'A fading actor best known for his portrayal of a popular superhero attempts to mount a comeback by appearing in a Broadway play. As opening night approaches, his attempts to…',
  },
  {
    id: 'tmdb_313369',
    tmdbId: 313369,
    title: 'La La Land',
    year: '2016',
    posterUrl: `${TMDB_IMAGE_BASE}/uDO8zWDhfWwoFdKS4fzkUJt0Rf0.jpg`,
    genres: ['Comedy', 'Drama', 'Romance'],
    overview: 'Mia, an aspiring actress, serves lattes to movie stars in between auditions and Sebastian, a jazz musician, scrapes by playing cocktail party gigs in dingy bars, but as success…',
  },
  {
    id: 'tmdb_496243',
    tmdbId: 496243,
    title: 'Parasite',
    year: '2019',
    posterUrl: `${TMDB_IMAGE_BASE}/7IiTTgloJzvGI1TAYymCfbfl3vT.jpg`,
    genres: ['Comedy', 'Thriller', 'Drama'],
    overview: 'All unemployed, Ki-taek\'s family takes peculiar interest in the wealthy and glamorous Parks for their livelihood until they get entangled in an unexpected incident.',
  },
  {
    id: 'tmdb_398978',
    tmdbId: 398978,
    title: 'The Irishman',
    year: '2019',
    posterUrl: `${TMDB_IMAGE_BASE}/mbm8k3GFhXS0ROd9AD1gqYbIFbM.jpg`,
    genres: ['Crime', 'Drama', 'History'],
    overview: 'Pennsylvania, 1956. Frank Sheeran, a war veteran of Irish origin who works as a truck driver, accidentally meets mobster Russell Bufalino. Once Frank becomes his trusted man,…',
  },
  {
    id: 'tmdb_545611',
    tmdbId: 545611,
    title: 'Everything Everywhere All at Once',
    year: '2022',
    posterUrl: `${TMDB_IMAGE_BASE}/u68AjlvlutfEIcpmbYpKcdi09ut.jpg`,
    genres: ['Action', 'Adventure', 'Sci-Fi'],
    overview: 'An aging Chinese immigrant is swept up in an insane adventure, where she alone can save what\'s important to her by connecting with the lives she could have led in other universes.',
  },
  {
    id: 'tmdb_76341',
    tmdbId: 76341,
    title: 'Mad Max: Fury Road',
    year: '2015',
    posterUrl: `${TMDB_IMAGE_BASE}/hA2ple9q4qnwxp3hKVNhroipsir.jpg`,
    genres: ['Action', 'Adventure', 'Sci-Fi'],
    overview: 'An apocalyptic story set in the furthest reaches of our planet, in a stark desert landscape where humanity is broken, and most everyone is crazed fighting for the necessities of…',
  },
  {
    id: 'tmdb_1726',
    tmdbId: 1726,
    title: 'Iron Man',
    year: '2008',
    posterUrl: `${TMDB_IMAGE_BASE}/78lPtwv72eTNqFW9COBYI0dWDJa.jpg`,
    genres: ['Action', 'Sci-Fi', 'Adventure'],
    overview: 'After being held captive in an Afghan cave, billionaire engineer Tony Stark creates a unique weaponized suit of armor to fight evil.',
  },
  {
    id: 'tmdb_68718',
    tmdbId: 68718,
    title: 'Django Unchained',
    year: '2012',
    posterUrl: `${TMDB_IMAGE_BASE}/7oWY8VDWW7thTzWh3OKYRkWUlD5.jpg`,
    genres: ['Drama', 'Western'],
    overview: 'With the help of a German bounty hunter, a freed slave sets out to rescue his wife from a brutal Mississippi plantation owner.',
  },
  {
    id: 'tmdb_24428',
    tmdbId: 24428,
    title: 'The Avengers',
    year: '2012',
    posterUrl: `${TMDB_IMAGE_BASE}/RYMX2wcKCBAr24UyPD7xwmjaTn.jpg`,
    genres: ['Sci-Fi', 'Action', 'Adventure'],
    overview: 'When an unexpected enemy emerges and threatens global safety and security, Nick Fury, director of the international peacekeeping agency known as S.H.I.E.L.D., finds himself in…',
  },
  {
    id: 'tmdb_299536',
    tmdbId: 299536,
    title: 'Avengers: Infinity War',
    year: '2018',
    posterUrl: `${TMDB_IMAGE_BASE}/7WsyChQLEftFiDOVTGkv3hFpyyt.jpg`,
    genres: ['Adventure', 'Action', 'Sci-Fi'],
    overview: 'As the Avengers and their allies have continued to protect the world from threats too large for any one hero to handle, a new danger has emerged from the cosmic shadows: Thanos. A…',
  },
  {
    id: 'tmdb_664',
    tmdbId: 664,
    title: 'Twister',
    year: '1996',
    posterUrl: `${TMDB_IMAGE_BASE}/d4ie3f6QTvNw40V770Uzo87SDZn.jpg`,
    genres: ['Action', 'Adventure', 'Drama'],
    overview: 'An unprecedented series of violent tornadoes is sweeping across Oklahoma. Tornado chasers, headed by Dr. Jo Harding, attempt to release a groundbreaking device that will allow…',
  },
];

/**
 * Widen a fixture entry to a full TMDBMovie so onboarding consumers (tier modal,
 * localStorage persistence, dedup) see the same shape as a live suggestion.
 */
export function toTMDBMovie(m: OnboardingFixtureMovie): TMDBMovie {
  return {
    id: m.id,
    tmdbId: m.tmdbId,
    title: m.title,
    year: m.year,
    posterUrl: m.posterUrl,
    backdropUrl: null,
    type: 'movie',
    genres: m.genres,
    overview: m.overview,
  };
}

/**
 * Fisher–Yates shuffle over a COPY of the pool (the source array is never
 * mutated). Called once per onboarding session so the signed-out grid varies
 * between loads; Refresh then pages through this shuffled order.
 */
export function shuffledFixturePool(): TMDBMovie[] {
  const pool = ONBOARDING_FIXTURE_MOVIES.map(toTMDBMovie);
  for (let i = pool.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [pool[i], pool[j]] = [pool[j], pool[i]];
  }
  return pool;
}
