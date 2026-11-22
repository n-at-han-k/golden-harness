{
  ast = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "10yknjyn0728gjn6b5syynvrvrwm66bhssbxq8mkhshxghaiailm";
      type = "gem";
    };
    version = "2.4.3";
  };
  ast-crispr = {
    dependencies = ["ast-merge" "service_actor" "version_gem"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1j4jvxfnral0v7v5a3kmabcbz01w9kw81l3zn1467ah278vrq89m";
      type = "gem";
    };
    version = "7.1.17";
  };
  ast-crispr-ruby-prism = {
    dependencies = ["ast-crispr" "prism-merge" "tree_haver" "version_gem"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1mhfr13gqfrfnpmy5sdp6jb8bx1bnjk10rkvd4v96c4wk8531rh3";
      type = "gem";
    };
    version = "7.1.17";
  };
  ast-merge = {
    dependencies = ["benchmark" "token-resolver" "tree_haver" "version_gem"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "09j4a93cppd3z67r59zw9qypxnyylyljnp1czzaqkrbz3x8m7w0r";
      type = "gem";
    };
    version = "7.1.17";
  };
  benchmark = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0v1337j39w1z7x9zs4q7ag0nfv4vs4xlsjx2la0wpv8s6hig2pa6";
      type = "gem";
    };
    version = "0.5.0";
  };
  citrus = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0l7nhk3gkm1hdchkzzhg2f70m47pc0afxfpl6mkiibc9qcpl3hjf";
      type = "gem";
    };
    version = "3.0.2";
  };
  decode = {
    dependencies = ["prism" "rbs"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0id8n5a020kpmdzjs6gvgpm1lj6i3maw1vpshw4vdw86s953crzm";
      type = "gem";
    };
    version = "0.30.0";
  };
  ffi = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1kqasqvy8d7r09ri4n6bkdwbk63j7afd9ilsw34nzlgh0qp69ldw";
      type = "gem";
    };
    version = "1.17.4";
  };
  ffi-clang = {
    dependencies = ["ffi"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "024jrn2l0l1s9znwlac0g4a2ln518nqz3x9slf70f042hz1jy02w";
      type = "gem";
    };
    version = "0.16.0";
  };
  json = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1n1v9rhb19cnf1a89s6yvvhw394jy8qnqx9sg8bn12g5zpwcrrrw";
      type = "gem";
    };
    version = "3.1.0";
  };
  language_server-protocol = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1w5p8c2145lmqzr25bxh4ikzjm6k8y1k5lriqqdpw9pq730w1wjy";
      type = "gem";
    };
    version = "3.17.0.6";
  };
  lint_roller = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "11yc0d84hsnlvx8cpk4cbj6a4dz9pk0r1k29p0n1fz9acddq831c";
      type = "gem";
    };
    version = "1.1.0";
  };
  logger = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "00q2zznygpbls8asz5knjvvj2brr3ghmqxgr83xnrdj4rk3xwvhr";
      type = "gem";
    };
    version = "1.7.0";
  };
  parallel = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0vvs2sar7wnw70j1jc1kv1k23m5grc0ci3bbrcf6mkh18683wnpp";
      type = "gem";
    };
    version = "2.3.0";
  };
  parser = {
    dependencies = ["ast" "racc"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "13z5jwb190xmvxq9kmdz82mi306bkl78h4fqw9g446dryxmggy32";
      type = "gem";
    };
    version = "3.3.14.0";
  };
  parslet = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "01pnw6ymz6nynklqvqxs4bcai25kcvnd5x4id9z3vd1rbmlk0lfl";
      type = "gem";
    };
    version = "2.0.0";
  };
  prism = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "11ggfikcs1lv17nhmhqyyp6z8nq5pkfcj6a904047hljkxm0qlvv";
      type = "gem";
    };
    version = "1.9.0";
  };
  prism-merge = {
    dependencies = ["ast-merge" "prism" "ruby-merge" "tree_haver" "version_gem"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "05fnl1c1d989hw7az55qq7858az018v80diz2fsylq9pvyv8gkgs";
      type = "gem";
    };
    version = "7.1.17";
  };
  racc = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0byn0c9nkahsl93y9ln5bysq4j31q8xkf2ws42swighxd4lnjzsa";
      type = "gem";
    };
    version = "1.8.1";
  };
  rainbow = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0smwg4mii0fm38pyb5fddbmrdpifwv22zv3d3px2xx497am93503";
      type = "gem";
    };
    version = "3.1.1";
  };
  rbs = {
    dependencies = ["logger" "prism" "tsort"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0x067q8cdam4kv5dc09iq2nzca8qm2kdl0dr22gc0ny0vj3bixsi";
      type = "gem";
    };
    version = "4.2.0";
  };
  regexp_parser = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0fwarpnqm6b0vy4yx3mhrx12zi0v435d0ywm8q4z1rjp9y0lf18x";
      type = "gem";
    };
    version = "2.13.4";
  };
  rubocop = {
    dependencies = ["json" "language_server-protocol" "lint_roller" "parallel" "parser" "rainbow" "regexp_parser" "rubocop-ast" "ruby-progressbar" "unicode-display_width"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1xigcyc13kn6lc0gs59m2zw5p7y508bqm1jgacx1rsg88sngwxzx";
      type = "gem";
    };
    version = "1.92.3";
  };
  rubocop-ast = {
    dependencies = ["ast" "parser" "prism" "racc"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0x6mrbfs8x8qz1abnpczb4wgam0g110r6by7whm51ml5hk988y82";
      type = "gem";
    };
    version = "1.53.0";
  };
  rubocop-disable_syntax = {
    dependencies = ["lint_roller" "rubocop"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0gppdbw0pxl5ygadykr7gi1mknzp0pv6bv4mx5s2zz5kfdbn8q8y";
      type = "gem";
    };
    version = "0.2.0";
  };
  rubocop-nathank = {
    dependencies = ["decode" "lint_roller" "prism" "rubocop"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1gsim1h8va09kflcsi899bg5dq7sdlwsp3qji6b8s1rbh7nr2wwd";
      type = "gem";
    };
    version = "2.1.0";
  };
  ruby-merge = {
    dependencies = ["ast-merge" "tree_haver" "version_gem"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0akydzy446pzv44422hpip524p8zqyapzi2y5ss0wz0zgg6z5b3r";
      type = "gem";
    };
    version = "7.1.17";
  };
  ruby-progressbar = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0cwvyb7j47m7wihpfaq7rc47zwwx9k4v7iqd9s1xch5nm53rrz40";
      type = "gem";
    };
    version = "1.13.0";
  };
  service_actor = {
    dependencies = ["zeitwerk"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1kirjmy89vw1n9bqa54wvssna9cdn09h3adjb4lyd9xr60v54fz6";
      type = "gem";
    };
    version = "3.9.4";
  };
  sorbet-runtime = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "09dw2ii2qi561g4xbzvljkc7malymg1bbcp5afmr0adbvcz30bkj";
      type = "gem";
    };
    version = "0.6.13715";
  };
  token-resolver = {
    dependencies = ["parslet" "version_gem"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "13pdqhwdrv9jvmid9cgriy8nx0d7xk7gga3rj5qspgi3rn0mi2s1";
      type = "gem";
    };
    version = "2.0.16";
  };
  tree_haver = {
    dependencies = ["citrus" "parslet" "tree_sitter_language_pack" "version_gem"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0fmfkw3m799anvnxjnkb9vq12gvi9ga0aqqb1n1s0ab2lac22lcx";
      type = "gem";
    };
    version = "7.1.17";
  };
  tree_sitter_language_pack = {
    dependencies = ["sorbet-runtime"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1sirqhxgpkbh1mfr3cqis0xa2mmzb64a3zpfpzgr647cxj16di23";
      type = "gem";
    };
    version = "1.25.0";
  };
  tsort = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "17q8h020dw73wjmql50lqw5ddsngg67jfw8ncjv476l5ys9sfl4n";
      type = "gem";
    };
    version = "0.2.0";
  };
  unicode-display_width = {
    dependencies = ["unicode-emoji"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "04xnl0zwpjjvxipd6rdnxkm11pfhbhhi3179yzv51nqi9dmacyjb";
      type = "gem";
    };
    version = "3.3.0";
  };
  unicode-emoji = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1kp89lja8ii7l6f0bq5vdxq1p3kxr3a2qmmhdc38qdwh6akjzh0i";
      type = "gem";
    };
    version = "4.3.0";
  };
  version_gem = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1zcdb8y8zhcwlz0m851vwmdx4kfxh1jyvf3ygrz7mdzvfnb0nhkh";
      type = "gem";
    };
    version = "1.1.17";
  };
  zeitwerk = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1rcjpgyzmdxp8rdw466156fmr588k9q1wg8j42g0dkk7hid1519c";
      type = "gem";
    };
    version = "2.8.3";
  };
}
