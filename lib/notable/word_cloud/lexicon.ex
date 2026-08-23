defmodule Notable.WordCloud.Lexicon do
  @moduledoc """
  Word lists used to filter audience feedback before it is projected.

  Two independent lists, both matched against a single already-normalised,
  case-folded token:

  * **Stopwords** — grammatical filler that would otherwise dominate any
    frequency count. The audience mixes Indonesian and English in one
    sentence, so both languages are covered by the same set.
  * **Blocklist** — profanity and slurs that must never reach a screen in
    front of a live room. This is a display-time safety rule, not moderation
    state: feedback is stored untouched and only filtered on the way out.

  Matching is deliberately **exact-token**, never substring. Substring
  matching produces the Scunthorpe problem, silently swallowing innocent
  words such as `assalamualaikum` for containing `ass`.
  """

  @indonesian_stopwords ~w(
    ada adalah adanya agar akan aku alah anda apa apakah atau ataupun bagi
    bagaimana bahkan bahwa banget belum berada bisa buat bukan cuma dalam dan
    dapat dari daripada dengan di dia dll dong dsb dulu gak ga gimana gitu
    guys habis hal hanya harus hingga ia ingin ini itu iya jadi jangan jika
    juga kalau kalo kami kamu kan karena ke kemudian kenapa kepada kita ku
    lagi lain lalu lebih maka makin mana masih mau melalui memang mereka
    merupakan mungkin nah namun nanti nya oleh pada padahal paling pun saat
    saja sama sangat saya se sebagai sebelum sedang sehingga sekali sekarang
    selain semua sendiri seperti serta setelah setiap siapa sih sudah supaya
    tak tapi telah tentang terhadap terlalu tersebut tetapi tidak tuh untuk
    walau walaupun yaitu yakni yang ya
  )

  @english_stopwords ~w(
    about after all also am an and any are as at be because been being but by
    can could did do does doing done down each even every for from further get
    got had has have having he her here hers him his how if in into is it its
    just like me more most much my no nor not now of off on once one only or
    other our out over own she should so some such than that the their them
    then there these they this those through to too under until up us very was
    we were what when where which while who whom why will with would you your
  )

  @blocklist ~w(
    anjing anjg anjir anjas asu asw babi bacot bajingan bangsat banci bego
    bencong bangke brengsek cok cocote coli colmek goblok idiot itil jancok
    jancuk jembut kampret keparat kimak kontol lonte memek monyet ngentot
    ngentod pantek peler pelacur pepek perek puki pukimak setan sialan sundal
    tai taik titit tolol

    arse ass asshole bastard bitch bollocks chink cock crap cunt dick dyke
    fag faggot fuck fucked fucking fucker kike motherfucker nigga nigger piss
    prick pussy retard retarded shit slut spic tranny twat wanker whore
  )

  # Plain maps, not MapSets: a MapSet literal baked into a module attribute
  # breaks the struct's opaque type and dialyzer rejects every lookup on it.
  @stopwords Map.new(@indonesian_stopwords ++ @english_stopwords, &{&1, true})
  @blocked Map.new(@blocklist, &{&1, true})

  @doc "True when `token` is Indonesian or English grammatical filler."
  def stopword?(token) when is_binary(token), do: Map.has_key?(@stopwords, token)

  @doc "True when `token` is profanity or a slur that must not be displayed."
  def blocked?(token) when is_binary(token), do: Map.has_key?(@blocked, token)

  @doc "The number of words on the display blocklist."
  def blocklist_size, do: map_size(@blocked)
end
