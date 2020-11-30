(** The test vectors are generated using https://github.com/dannywillems/ocaml-ff *)
let test_vectors =
  [ "5241434266765085153989819426158356963249585137477420674959011812945457865191";
    "10839440052692226066497714164180551800338639216929046788248680350103009908352";
    "45771516566988367809715142190959127910391288669516577059039340716912455457131";
    "12909915968096385929046240252673624834885730199746273136167032454235900707423";
    "9906806778085203695146840231942453635945512651510460213691437498308396392030";
    "20451006147593515828371694915490427948041026610654337997907355913265840025855";
    "22753274685202779061111872324861161292260930710591061598808549358079414450472";
    "12823588949385074189879212809942339506958509313775057573450243545256259992541";
    "3453";
    "323580923485092809298430986453";
    "984305293863456098093285";
    "235234634090909863456";
    "24352346534563452436524356";
    "3836944629596737352";
    "65363576374567456780984059630856836098740965874094860978";
    "546574608450909809809809824360345639808560937" ]

let rec random_z () =
  let size = Random.int Bls12_381.Fr.size_in_bytes in
  if size = 0 then random_z ()
  else
    let r = Bytes.init size (fun _ -> char_of_int (Random.int 256)) in
    Z.erem (Z.of_bits (Bytes.to_string r)) Bls12_381.Fr.order

let rec repeat n f =
  if n <= 0 then
    let f () = () in
    f
  else (
    f () ;
    repeat (n - 1) f )

module ValueGeneration = Test_ff_make.MakeValueGeneration (Bls12_381.Fr)
module IsZero = Test_ff_make.MakeIsZero (Bls12_381.Fr)
module Equality = Test_ff_make.MakeEquality (Bls12_381.Fr)
module FieldProperties = Test_ff_make.MakeFieldProperties (Bls12_381.Fr)

module StringRepresentation = struct
  let test_to_string_one () =
    assert (String.equal "1" (Bls12_381.Fr.to_string Bls12_381.Fr.one))

  let test_to_string_zero () =
    assert (String.equal "0" (Bls12_381.Fr.to_string Bls12_381.Fr.zero))

  let test_of_string_with_of_z () =
    List.iter
      (fun x ->
        assert (
          Bls12_381.Fr.eq
            (Bls12_381.Fr.of_string x)
            (Bls12_381.Fr.of_z (Z.of_string x)) ))
      test_vectors

  let test_of_string_to_string_consistency () =
    List.iter
      (fun x ->
        assert (
          String.equal (Bls12_381.Fr.to_string (Bls12_381.Fr.of_string x)) x ))
      test_vectors

  let get_tests () =
    let open Alcotest in
    ( "String representation",
      [ test_case "one" `Quick test_to_string_one;
        test_case
          "consistency of_string with of_z with test vectors"
          `Quick
          test_of_string_with_of_z;
        test_case
          "consistency of_string to_string with test vectors"
          `Quick
          test_of_string_to_string_consistency;
        test_case "zero" `Quick test_to_string_zero ] )
end

module ZRepresentation = struct
  let test_of_z_zero () =
    assert (Bls12_381.Fr.eq Bls12_381.Fr.zero (Bls12_381.Fr.of_z Z.zero))

  let test_of_z_one () =
    assert (
      Bls12_381.Fr.eq Bls12_381.Fr.one (Bls12_381.Fr.of_z (Z.of_string "1")) )

  let test_random_of_z_and_to_z () =
    let x = Bls12_381.Fr.random () in
    assert (Bls12_381.Fr.eq x (Bls12_381.Fr.of_z (Bls12_381.Fr.to_z x)))

  let test_random_to_z_and_of_z () =
    let x = random_z () in
    assert (Z.equal (Bls12_381.Fr.to_z (Bls12_381.Fr.of_z x)) x)

  let test_vectors_to_z_and_of_z () =
    let test_vectors = List.map Z.of_string test_vectors in
    List.iter
      (fun x -> assert (Z.equal (Bls12_381.Fr.to_z (Bls12_381.Fr.of_z x)) x))
      test_vectors

  let get_tests () =
    let open Alcotest in
    ( "Z representation",
      [ test_case "one" `Quick test_of_z_one;
        test_case "zero" `Quick test_of_z_zero;
        test_case
          "of z and to z with random small numbers"
          `Quick
          (repeat 1000 test_random_of_z_and_to_z);
        test_case
          "to z and of z with test vectors"
          `Quick
          test_vectors_to_z_and_of_z;
        test_case
          "to z and of z with random small numbers"
          `Quick
          (repeat 1000 test_random_to_z_and_of_z) ] )
end

module BytesRepresentation = struct
  let test_bytes_repr_is_zarith_encoding_using_to_bits () =
    (* Pad zarith repr *)
    let r_z = random_z () in
    let bytes_z = Bytes.of_string (Z.to_bits r_z) in
    let bytes = Bytes.make Bls12_381.Fr.size_in_bytes '\000' in
    Bytes.blit
      bytes_z
      0
      bytes
      0
      (min (Bytes.length bytes_z) Bls12_381.Fr.size_in_bytes) ;
    assert (
      Bls12_381.Fr.eq
        (Bls12_381.Fr.of_bytes_exn bytes)
        (Bls12_381.Fr.of_string (Z.to_string r_z)) ) ;
    let r = Bls12_381.Fr.random () in
    (* Use Fr repr *)
    let bytes_r = Bls12_381.Fr.to_bytes r in
    (* Use the Fr repr to convert in a Z element *)
    let z_r = Z.of_bits (Bytes.to_string bytes_r) in
    (* We should get the same value, using both ways *)
    assert (Z.equal z_r (Bls12_381.Fr.to_z r)) ;
    assert (Bls12_381.Fr.(eq (of_z z_r) r))

  let test_padding_is_done_automatically_with_of_bytes () =
    let z = Z.of_string "32343543534" in
    let z_bytes = Bytes.of_string (Z.to_bits z) in
    (* Checking we are in the case requiring a padding *)
    assert (Bytes.length z_bytes < Bls12_381.Fr.size_in_bytes) ;
    (* Should not raise an exception *)
    let e = Bls12_381.Fr.of_bytes_exn z_bytes in
    (* Should not be an option *)
    assert (Option.is_some (Bls12_381.Fr.of_bytes_opt z_bytes)) ;
    (* Equality in Fr should be fine (require to check to verify the
       internal representation is the same). In the current implementation, we
       verify the internal representation is the padded version.
    *)
    assert (Bls12_381.Fr.(eq (of_z z) e)) ;
    (* And as zarith elements, we also have the equality *)
    assert (Z.equal (Bls12_381.Fr.to_z e) z)

  let get_tests () =
    let open Alcotest in
    ( "Bytes representation",
      [ test_case
          "bytes representation is the same than zarith using Z.to_bits"
          `Quick
          (repeat 1000 test_bytes_repr_is_zarith_encoding_using_to_bits);
        test_case
          "Padding is done automatically with of_bytes"
          `Quick
          test_padding_is_done_automatically_with_of_bytes ] )
end

module TestVector = struct
  let test_inverse () =
    let test_vectors =
      [ ( "5241434266765085153989819426158356963249585137477420674959011812945457865191",
          "10839440052692226066497714164180551800338639216929046788248680350103009908352"
        );
        ( "45771516566988367809715142190959127910391288669516577059039340716912455457131",
          "45609475631078884634858595528211458305369692448866344559573507066772305338186"
        );
        ( "12909915968096385929046240252673624834885730199746273136167032454235900707423",
          "11000310335493461593980032382804784919007817741315871286620011674413549793814"
        );
        ( "9906806778085203695146840231942453635945512651510460213691437498308396392030",
          "14376170892131209521313997949250266279614396523892055155196474364730307649110"
        );
        ( "20451006147593515828371694915490427948041026610654337997907355913265840025855",
          "9251674366848220983783993301665718813823734287374642487691950418950023775049"
        );
        ( "22753274685202779061111872324861161292260930710591061598808549358079414450472",
          "5879182491359474138365930955028927605587956455972550635628359324770111549635"
        );
        ( "12823588949385074189879212809942339506958509313775057573450243545256259992541",
          "37176703988340956294235799427206509384158992510189606907136259793202107500314"
        ) ]
    in
    List.iter
      (fun (e, i) ->
        assert (
          Bls12_381.Fr.eq
            (Bls12_381.Fr.inverse_exn (Bls12_381.Fr.of_string e))
            (Bls12_381.Fr.of_string i) ))
      test_vectors ;
    List.iter
      (fun (e, i) ->
        assert (
          Bls12_381.Fr.eq
            (Bls12_381.Fr.inverse_exn (Bls12_381.Fr.of_string i))
            (Bls12_381.Fr.of_string e) ))
      test_vectors

  let test_add () =
    let test_vectors =
      [ ( "52078196679215712148218322720576334474579224383898730538745959257577939031988",
          "14304697501712570926435354702070278490052573047716755203338045808050772484669",
          "13947019005802092595205936914460647126941244931087847919480346365690130332144"
        );
        ( "19157304358764478240694328289471146271697961435094141547920922715555209453450",
          "11728945318991987128312512931314113966598035268029910445432277435051890961717",
          "30886249677756465369006841220785260238295996703124051993353200150607100415167"
        );
        ( "31296266781120594533063853258918717262467469319142606380721992558348378328397",
          "5820131821230508181650789592096633040648713066445785718497340531185653967933",
          "37116398602351102714714642851015350303116182385588392099219333089534032296330"
        );
        ( "39560938173284521169378001220360644956845338274621437250191508195058982219820",
          "38064607903920408690614292538356509340138834185257338707027916971694121463660",
          "25189670902078739380544553250531188459293619959351138134615766466814522498967"
        ) ]
    in
    List.iter
      (fun (e1, e2, expected_result) ->
        assert (
          Bls12_381.Fr.eq
            (Bls12_381.Fr.add
               (Bls12_381.Fr.of_string e1)
               (Bls12_381.Fr.of_string e2))
            (Bls12_381.Fr.of_string expected_result) ))
      test_vectors ;
    List.iter
      (fun (e1, e2, expected_result) ->
        assert (
          Bls12_381.Fr.eq
            (Bls12_381.Fr.add
               (Bls12_381.Fr.of_string e2)
               (Bls12_381.Fr.of_string e1))
            (Bls12_381.Fr.of_string expected_result) ))
      test_vectors

  let test_mul () =
    let test_vectors =
      [ ( "38060637728987323531851344110399976342797446962849502240683562298774992708830",
          "5512470721848092388961431210636327528269807331564913139270778763494220846493",
          "37668727721438606074520892100332665478321086205735021165111387339937557071514"
        );
        ( "8920353329234094921489611026184774357268414518382488349470656930013415883424",
          "49136653454012368208567167956110520759637791556856057105423947118262807325779",
          "15885623306930744461021285813204059242301068985087295733128928505332635787610"
        );
        ( "27505619973888738863986068934484781011766945824263356612923712981356457561202",
          "50243072596783212750626991643373709632302860135434554488507947926966036993873",
          "41343614115054986651575849604178072836351973556978705402848027675783507031010"
        );
        ( "22595773174612669619067973477148714090185633332320792125410903789347752011910",
          "52328732251934881978597625733405265672319639896554870653166667703616699256860",
          "40257812317025926695523520096471471069294532648049850170792668232075952784083"
        ) ]
    in
    List.iter
      (fun (e1, e2, expected_result) ->
        assert (
          Bls12_381.Fr.eq
            (Bls12_381.Fr.mul
               (Bls12_381.Fr.of_string e1)
               (Bls12_381.Fr.of_string e2))
            (Bls12_381.Fr.of_string expected_result) ))
      test_vectors ;
    List.iter
      (fun (e1, e2, expected_result) ->
        assert (
          Bls12_381.Fr.eq
            (Bls12_381.Fr.mul
               (Bls12_381.Fr.of_string e2)
               (Bls12_381.Fr.of_string e1))
            (Bls12_381.Fr.of_string expected_result) ))
      test_vectors

  let test_opposite () =
    let test_vectors =
      [ ( "41115813042790628185693779037818020465346656435243125143422155873970076434871",
          "11320062132335562293753961470367945372343896065284512679181502825968504749642"
        );
        ( "42018322502149629012634568822875196842144777572867508162082880801617895571737",
          "10417552672976561466813171685310768995545774927660129660520777898320685612776"
        );
        ( "34539139262525805815749017833342205015904514998269280061826808173178967747220",
          "17896735912600384663698722674843760821786037502258357760776850526759613437293"
        );
        ( "48147683698672565222275497827671970468018938121714425045755179114542522684737",
          "4288191476453625257172242680513995369671614378813212776848479585396058499776"
        ) ]
    in
    List.iter
      (fun (e1, expected_result) ->
        assert (
          Bls12_381.Fr.eq
            (Bls12_381.Fr.negate (Bls12_381.Fr.of_string e1))
            (Bls12_381.Fr.of_string expected_result) ))
      test_vectors ;
    List.iter
      (fun (e1, expected_result) ->
        assert (
          Bls12_381.Fr.eq
            (Bls12_381.Fr.negate (Bls12_381.Fr.of_string expected_result))
            (Bls12_381.Fr.of_string e1) ))
      test_vectors

  let test_pow () =
    let test_vectors =
      [ ( "19382565044794829105685946147333667407406947769919002500736830762980080217116",
          "48159949448997187908979844521309454081051202554580566653703924472697903187543",
          "51805065919052658973952545206023802114592698824188349145165662267033488307015"
        );
        ( "38434293760957543250833416278928537431247174199351417891430036507051711516795",
          "19350167110479287515066444930433610752856061045118438172892254847951537570134",
          "5638414748000331847846282606999064802458819295656595143203518899742396580213"
        );
        ( "49664271363539622878107770584406780589976347771473156015482691689195652813880",
          "19379581748332915194987329063856477906332155141792491408304078230104564222030",
          "30921874175813683797322233883008640815321607592610957475928976635504264297632"
        );
        ( "51734967732893479663302261399661867713222970046133566655959761380034878973281",
          "37560370265646062523028551976728263929547556442627149817510607017268305870511",
          "49814797937772261149726667662726741057831444313882786994092918399718266462922"
        ) ]
    in
    List.iter
      (fun (x, e, expected_result) ->
        assert (
          Bls12_381.Fr.eq
            (Bls12_381.Fr.pow (Bls12_381.Fr.of_string x) (Z.of_string e))
            (Bls12_381.Fr.of_string expected_result) ))
      test_vectors

  let get_tests () =
    let open Alcotest in
    ( "Test vectors",
      [ test_case "inverse" `Quick test_inverse;
        test_case "add" `Quick test_add;
        test_case "opposite" `Quick test_opposite;
        test_case "pow" `Quick test_pow;
        test_case "multiplication" `Quick test_mul ] )
end

let () =
  let open Alcotest in
  run
    "Fr"
    [ IsZero.get_tests ();
      ValueGeneration.get_tests ();
      Equality.get_tests ();
      FieldProperties.get_tests ();
      TestVector.get_tests ();
      ZRepresentation.get_tests ();
      BytesRepresentation.get_tests ();
      StringRepresentation.get_tests () ]
