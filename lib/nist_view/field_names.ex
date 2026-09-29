defmodule NistView.FieldNames do
  @moduledoc """
  Mnemonics for field numbers, from ANSI/NIST-ITL 1-2011 (Update:2015).

  Deliberately incomplete: a field missing here is shown by number only,
  which is better than a wrong name. Binary Type-3 to Type-8 records use
  the numbering `NistView.Parser` gives their fixed-layout fields.
  """

  @type1 %{
    1 => "LEN",
    2 => "VER",
    3 => "CNT",
    4 => "TOT",
    5 => "DAT",
    6 => "PRY",
    7 => "DAI",
    8 => "ORI",
    9 => "TCN",
    10 => "TCR",
    11 => "NSR",
    12 => "NTR",
    13 => "DOM",
    14 => "GMT",
    15 => "DCS",
    16 => "APS",
    17 => "ANM",
    18 => "GNS"
  }

  @header %{1 => "LEN", 2 => "IDC"}

  # Type-3 to Type-6 share Type-4's fixed layout.
  @binary_image Map.merge(@header, %{
                  3 => "IMP",
                  4 => "FGP",
                  5 => "ISR",
                  6 => "HLL",
                  7 => "VLL",
                  8 => "CGA",
                  9 => "DATA"
                })

  @type7 Map.merge(@header, %{3 => "DATA"})

  @type8 Map.merge(@header, %{
           3 => "SIG",
           4 => "SRT",
           5 => "ISR",
           6 => "HLL",
           7 => "VLL",
           8 => "DATA"
         })

  @type9 Map.merge(@header, %{
           3 => "IMP",
           4 => "FMT",
           5 => "OFR",
           6 => "FGP",
           7 => "FPC",
           8 => "CRP",
           9 => "DLT",
           10 => "MIN",
           11 => "RDG",
           12 => "MRC",
           # INCITS 378 (M1) block
           126 => "CBI",
           127 => "CEI",
           128 => "HLL",
           129 => "VLL",
           130 => "SLC",
           131 => "THPS",
           132 => "TVPS",
           133 => "FVW",
           134 => "FGP",
           135 => "FQD",
           136 => "NOM",
           137 => "FMD",
           138 => "RCI",
           139 => "CIN",
           140 => "DIN",
           141 => "ADA",
           # Extended Feature Set (EFS) block
           300 => "ROI",
           302 => "FPP",
           320 => "COR",
           321 => "DEL",
           331 => "MIN",
           332 => "MRA",
           333 => "MRC"
         })

  # Fields shared by the tagged image records (Type-10 and up).
  @image Map.merge(@header, %{
           4 => "SRC",
           6 => "HLL",
           7 => "VLL",
           8 => "SLC",
           9 => "THPS",
           10 => "TVPS",
           11 => "CGA",
           12 => "BPX",
           902 => "ANN",
           903 => "DUI",
           904 => "MMS",
           993 => "SAN",
           995 => "ASC",
           996 => "HAS",
           997 => "SOR",
           998 => "GEO",
           999 => "DATA"
         })

  @type10 Map.merge(@image, %{
            3 => "IMT",
            5 => "PHD",
            12 => "CSP",
            13 => "SAP",
            14 => "FIP",
            15 => "FPFI",
            16 => "SHPS",
            17 => "SVPS",
            18 => "DIST",
            19 => "LAF",
            20 => "POS",
            21 => "POA",
            23 => "PAS",
            24 => "SQS",
            25 => "SPA",
            26 => "SXS",
            27 => "SEC",
            40 => "SMT",
            41 => "SMS",
            42 => "SMD",
            43 => "COL"
          })

  @friction_ridge Map.merge(@image, %{
                    3 => "IMP",
                    13 => "FGP",
                    16 => "SHPS",
                    17 => "SVPS",
                    20 => "COM"
                  })

  @type13 Map.merge(@friction_ridge, %{5 => "LCD", 14 => "SPD", 15 => "PPC", 24 => "LQM"})

  @type14 Map.merge(@friction_ridge, %{
            5 => "FCD",
            14 => "PPD",
            15 => "PPC",
            18 => "AMP",
            21 => "SEG",
            22 => "NQM",
            23 => "SQM",
            24 => "FQM",
            25 => "ASEG",
            26 => "SCF",
            27 => "SIF",
            30 => "DMM",
            31 => "FAP"
          })

  @type15 Map.merge(@friction_ridge, %{5 => "PCD", 18 => "AMP", 24 => "PQM", 30 => "DMM"})

  @type17 Map.merge(@image, %{3 => "ELR", 5 => "ICD", 13 => "CSP"})

  @type99 Map.merge(@header, %{
            4 => "SRC",
            100 => "HDV",
            101 => "BTY",
            102 => "BDQ",
            103 => "BFO",
            104 => "BFT",
            999 => "BDB"
          })

  @names %{
    1 => @type1,
    2 => @header,
    3 => @binary_image,
    4 => @binary_image,
    5 => @binary_image,
    6 => @binary_image,
    7 => @type7,
    8 => @type8,
    9 => @type9,
    10 => @type10,
    13 => @type13,
    14 => @type14,
    15 => @type15,
    16 => Map.put(@image, 13, "CSP"),
    17 => @type17,
    99 => @type99
  }

  @record_names %{
    1 => "Transaction information",
    2 => "User-defined descriptive text",
    3 => "Low-resolution grayscale fingerprint (deprecated)",
    4 => "High-resolution grayscale fingerprint",
    5 => "Low-resolution binary fingerprint (deprecated)",
    6 => "High-resolution binary fingerprint (deprecated)",
    7 => "User-defined image",
    8 => "Signature image",
    9 => "Minutiae data",
    10 => "Photographic body part imagery",
    11 => "Forensic and investigatory voice data",
    12 => "Forensic dental and oral data",
    13 => "Friction-ridge latent image",
    14 => "Variable-resolution fingerprint image",
    15 => "Variable-resolution palm print image",
    16 => "User-defined variable-resolution testing image",
    17 => "Iris image",
    18 => "DNA data",
    19 => "Variable-resolution plantar image",
    20 => "Source representation",
    21 => "Associated context",
    22 => "Non-photographic imagery",
    98 => "Information assurance",
    99 => "CBEFF biometric data"
  }

  @doc "The mnemonic for field `type.number`, or nil if unknown."
  @spec field(non_neg_integer(), non_neg_integer()) :: String.t() | nil
  def field(type, number) do
    case Map.fetch(@names, type) do
      {:ok, names} -> Map.get(names, number)
      :error -> Map.get(if(type >= 10, do: @image, else: @header), number)
    end
  end

  @doc "A short description of a record type, or nil if unknown."
  @spec record(non_neg_integer()) :: String.t() | nil
  def record(type), do: Map.get(@record_names, type)
end
