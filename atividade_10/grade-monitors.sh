#!/bin/bash
# Usage: grade dir_or_archive [output]

# Ensure realpath 
realpath . &>/dev/null
HAD_REALPATH=$(test "$?" -eq 127 && echo no || echo yes)
if [ "$HAD_REALPATH" = "no" ]; then
  cat > /tmp/realpath-grade.c <<EOF
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char** argv) {
  char* path = argv[1];
  char result[8192];
  memset(result, 0, 8192);

  if (argc == 1) {
      printf("Usage: %s path\n", argv[0]);
      return 2;
  }
  
  if (realpath(path, result)) {
    printf("%s\n", result);
    return 0;
  } else {
    printf("%s\n", argv[1]);
    return 1;
  }
}
EOF
  cc -o /tmp/realpath-grade /tmp/realpath-grade.c
  function realpath () {
    /tmp/realpath-grade $@
  }
fi

INFILE=$1
if [ -z "$INFILE" ]; then
  CWD_KBS=$(du -d 0 . | cut -f 1)
  if [ -n "$CWD_KBS" -a "$CWD_KBS" -gt 20000 ]; then
    echo "Chamado sem argumentos."\
         "Supus que \".\" deve ser avaliado, mas esse diretório é muito grande!"\
         "Se realmente deseja avaliar \".\", execute $0 ."
    exit 1
  fi
fi
test -z "$INFILE" && INFILE="."
INFILE=$(realpath "$INFILE")
# grades.csv is optional
OUTPUT=""
test -z "$2" || OUTPUT=$(realpath "$2")
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
# Absolute path to this script
THEPACK="${DIR}/$(basename "${BASH_SOURCE[0]}")"
STARTDIR=$(pwd)

# Split basename and extension
BASE=$(basename "$INFILE")
EXT=""
if [ ! -d "$INFILE" ]; then
  BASE=$(echo $(basename "$INFILE") | sed -E 's/^(.*)(\.(c|zip|(tar\.)?(gz|bz2|xz)))$/\1/g')
  EXT=$(echo  $(basename "$INFILE") | sed -E 's/^(.*)(\.(c|zip|(tar\.)?(gz|bz2|xz)))$/\2/g')
fi

# Setup working dir
rm -fr "/tmp/$BASE-test" || true
mkdir "/tmp/$BASE-test" || ( echo "Could not mkdir /tmp/$BASE-test"; exit 1 )
UNPACK_ROOT="/tmp/$BASE-test"
cd "$UNPACK_ROOT"

function cleanup () {
  test -n "$1" && echo "$1"
  cd "$STARTDIR"
  rm -fr "/tmp/$BASE-test"
  test "$HAD_REALPATH" = "yes" || rm /tmp/realpath-grade* &>/dev/null
  return 1 # helps with precedence
}

# Avoid messing up with the running user's home directory
# Not entirely safe, running as another user is recommended
export HOME=.

# Check if file is a tar archive
ISTAR=no
if [ ! -d "$INFILE" ]; then
  ISTAR=$( (tar tf "$INFILE" &> /dev/null && echo yes) || echo no )
fi

# Unpack the submission (or copy the dir)
if [ -d "$INFILE" ]; then
  cp -r "$INFILE" . || cleanup || exit 1 
elif [ "$EXT" = ".c" ]; then
  echo "Corrigindo um único arquivo .c. O recomendado é corrigir uma pasta ou  arquivo .tar.{gz,bz2,xz}, zip, como enviado ao moodle"
  mkdir c-files || cleanup || exit 1
  cp "$INFILE" c-files/ ||  cleanup || exit 1
elif [ "$EXT" = ".zip" ]; then
  unzip "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".tar.gz" ]; then
  tar zxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".tar.bz2" ]; then
  tar jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".tar.xz" ]; then
  tar Jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".gz" -a "$ISTAR" = "yes" ]; then
  tar zxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".gz" -a "$ISTAR" = "no" ]; then
  gzip -cdk "$INFILE" > "$BASE" || cleanup || exit 1
elif [ "$EXT" = ".bz2" -a "$ISTAR" = "yes"  ]; then
  tar jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".bz2" -a "$ISTAR" = "no" ]; then
  bzip2 -cdk "$INFILE" > "$BASE" || cleanup || exit 1
elif [ "$EXT" = ".xz" -a "$ISTAR" = "yes"  ]; then
  tar Jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".xz" -a "$ISTAR" = "no" ]; then
  xz -cdk "$INFILE" > "$BASE" || cleanup || exit 1
else
  echo "Unknown extension $EXT"; cleanup; exit 1
fi

# There must be exactly one top-level dir inside the submission
# As a fallback, if there is no directory, will work directly on 
# tmp/$BASE-test, but in this case there must be files! 
function get-legit-dirs  {
  find . -mindepth 1 -maxdepth 1 -type d | grep -vE '^\./__MACOS' | grep -vE '^\./\.'
}
NDIRS=$(get-legit-dirs | wc -l)
test "$NDIRS" -lt 2 || \
  cleanup "Malformed archive! Expected exactly one directory, found $NDIRS" || exit 1
test  "$NDIRS" -eq  1 -o  "$(find . -mindepth 1 -maxdepth 1 -type f | wc -l)" -gt 0  || \
  cleanup "Empty archive!" || exit 1
if [ "$NDIRS" -eq 1 ]; then #only cd if there is a dir
  cd "$(get-legit-dirs)"
fi

# Unpack the testbench
tail -n +$(($(grep -ahn  '^__TESTBENCH_MARKER__' "$THEPACK" | cut -f1 -d:) +1)) "$THEPACK" | tar zx
cd testbench || cleanup || exit 1

# Deploy additional binaries so that validate.sh can use them
test "$HAD_REALPATH" = "yes" || cp /tmp/realpath-grade "tools/realpath"
cc -std=c11 tools/wrap-function.c -o tools/wrap-function \
  || echo "Compilation of wrap-function.c failed. If you are on a Mac, brace for impact"
export PATH="$PATH:$(realpath "tools")"

# Run validate
(./validate.sh 2>&1 | tee validate.log) || cleanup || exit 1

# Write output file
if [ -n "$OUTPUT" ]; then
  #write grade
  echo "@@@###grade:" > result
  cat grade >> result || cleanup || exit 1
  #write feedback, falling back to validate.log
  echo "@@@###feedback:" >> result
  (test -f feedback && cat feedback >> result) || \
    (test -f validate.log && cat validate.log >> result) || \
    cleanup "No feedback file!" || exit 1
  #Copy result to output
  test ! -d "$OUTPUT" || cleanup "$OUTPUT is a directory!" || exit 1
  rm -f "$OUTPUT"
  cp result "$OUTPUT"
fi

if ( ! grep -E -- '-[0-9]+' grade &> /dev/null ); then
   echo -e "Grade for $BASE$EXT: $(cat grade)"
fi

cleanup || true

exit 0

__TESTBENCH_MARKER__
�      �<�v�8�y�W��:�d��Y�t��$J�O;���L|�rki��P��t�~�/�3�4_��* $��.N;���DX(�U����9u��ƽ�֚�w���z�mʟQ���t����N��ƽf�����#��GR�B?�=B��6����p����� �ຶ�]�����t7V��������O��1�un��E��x�����F�u�4og���?\�����8�������ݣ�᫝�~��*��9<:�J#�##˦�rH��&1�!ֈ��2!u��4��&	.����5R���5C5.\��B�i0���sM�@����ؗ��?�*0TG�p�TC��B�T��R�M��X����Lס�@m���\������v�m��׌[��������}��]��Vs���ݷ�MJ���i���VI��,g��3m�<���1�Ʈ��Ļ�d
kJe/�A��~P#D���W��fI<R��Te��\ CH��nH�<Z�PU�I�����Õg�x��Ѐ^�6h�[���76�	��e�|����/�Z�t�NlS *��_�'���~�8J�!:m��l�(�����R�s ��H�4y?�A��z����ݭ�*��h�|�/��Ny<GAE�6��B�D௑)=����5iֈo�F�Q��J%�ԊAl�Ab�8�)�yA�� W�5��C�ZCe�����A{��2�3@;�|R"��BepC�m�P[54=�:*#�B֣�L���J��m]F���:��UIT�<�� cL?�1'5�%��#Sc��0S�&O߬Y~����ߩd�Ol'�d�L�Rd�]��o�x�J�LrW�H�#<�-iID(�_O9���z����5�?�gU�Y�7T��z%+Tu0PO�tV��z���<k���<�݉�yk�*w�R| �Ϙ�J%Y�c7p�aS�	���bF��ȗ�dx��H�Bm0�� ���}u����E	"��h[�LP|ru��>��]��.9�~�@D_O�d��3���G0������9�
�����Rbґ�X,�P��|��3E�Rbu��$�U�SҜ�wf.&*�<B��D��[f&_�������D�ڄ<kB�̡	,O�nУ4���~I��XR�D{���@��IL'�p��!k?�y��ܗ�e�Q��S¼��1�Q�P�F�?�'���������^����^L^�?D��� �\�8	<=lJi*' ���M��@�T:�C&��O���>��i=�?1f�]��D"U&ͅ;
�7T���ȝ2�[�S"%���WGS�����A��I1��qp�j��g�=��R3�bD�"�ˑ�rD�
�вtS|����Tг4e�23䰒�㙓$�rdخO&�`9|l�7�H-��"q���q$,v�̊�nh��|1E�!6���7RҢI�Q8�ڈ1���?F=k�Rnz4�C�BRyFz�Tf3��Str��L�p�1�P����X�!R�/��8ñ�S�����G����no���C�Rod���N��F�c�S<u�/tj��H5b!����1C�$��2���4M�����I�?���>F|�BV�@���A��E,�I������+�j��SF�T�/����L��`�0�:���2�gQ�:y�|�����]�	)��3͛������F�wP�"�3J�'��S�5����J8e�f���f��T'S�÷��d-�ͦ����]խ�V]Uj��+�:o�����7Q�o�6��,�[,�DhgP����m
JkٵU� H ��+"od�!L�G�b�������i�+�t��Q�wi�������~�[��ͱ�������v��ǫ���h�����K��{��=��ۥ�o��{������+o�^��/�o���W��|H�!J9�U���$i���ᄶ]*ٖM��1uXRCȈ.���'x�_l٦G�^Y���e�H�>�O���`>����_4 ���N� ����'�7��2��Md��=�*"���n���M�<#q&�8��/H}����2�{QߦtJ�L�����`d+V�=���{~��o`%����<p}��?/�MkBY@���z�c�x��pB�nh���)B.9Z��%��Kl)�#ҏ9�k�-
��2�����.����������b�p��LX�q&TzX�}1�k�3��|ȴ���U�P�)!F&9���*�H`w��Ą�+p}%��/��x�|H-�����*�,BJ����T��Zq�˯O�7��m̱(�wg���G���;ir�/�|���?�s̪����ۥ��a'�S���,��\��n4���`�5���%2��hF����~&��RK ���&�r�ۡh�!?6�C;`�\����;i?%��o� |�3t���}���L�:�5���y�睽�.�c�e�z�b���ٳ���[O`��� b�#�"u�	|�����V�' �z	l,�GG_ ��{ɦt�F����F��J%�$O��OΪO�5����TqעI#L���GP��-.���G��
-��x�8c����R����a���DJ���*hC8<�K1��Y)�v�#��d��) ;���1X�d&|�(eK�Dp��xU ![[9v�`"2�sU	�;_^H�)������S�ST��}X�~�3��O�l����h������LJ�'X�M�r�!����x���a@C0P؝%Oiټ�&rvU|2 4-�����h�f�1~XQ�V�Q�Vy�hI��N����N��oq���[���������]�)����W�ohz`]Z&x�V��&�덵w�cڶ�S/�̿@�I�]k�㸁�
I�\7Z�2���m{��q��Y���/\ۦ�D���l�=�Ѓ]q�UR}��(�_;��A��S�����;c�IBH��A!Xvv�[�A������9���{yM�s����$Y��Otp���rt���S�x�l�����z�;��v����L�A�>G?�T�隳��s�|�A���i@���A�,����*1���@�����1�Kr{|�7��?zġW�O�ǈ5{��l�H�L���ta�
�Fa�8�@��	���y�^Hg�pK�9��@���5vF�JU�H������N�c:r�X��<	�\�IQ �5ě*$͚D����͂�-�~+72\zOٺ�"�/4/�[j�F��s���d��]�ǂ^�ƶ���?�W��pR`9_��ךD-�5v\��"��,����Ms	��
Y���4C����^A�*�wW�3\��8��Md;��ʜ`����sz�_RS��bR� ����V3W���G�J�oݯ,j���B�����f�z��I���j�N�=h�� Y�k$K|�R�� B)���t¦��d�g��& ?�B�jLdƳ̃=AA�\���!n���x���K��7$�ߘ֕����U`a~)$�S��a5�z�rR�a��Æ6�x�����;��4����/k�y��1��9L�����,ݾuF�Z�7�v�%~�,��v�nAp�?���ŕ�X/���߆� OnO�KHp�p"	~�p:l�<�p.�M�h8nt�8D�hDa)�G��kq���7�]C��O��qA� �fR}Iu�ɵg&'`f�wkfK-��@��PZ�Eݍe	A��_lZ7\=�箞���/��_���Dkg�a���X������?�-g�1�~�Hl�;D��q��G{�N��:���U["���-����D$�2q��#��
Ƞ����o�f���Qc�i������@-�qZ�h����d��F��X��K<!ゎ�X+�xR���$���׿c]�����y]�����
\�����������'Sפ�a �KorJ�2�@�4�5"�J�,&OdL��͐�>��2ߘひ�b
Ϣ���(�O�:�g�lU���<�X~�	E�\#9�HNaI �-:����>��'���wl��X��>�r x���o^E8�Uc�fW��u��!����W�.�ر��9%��tcL,\�3�-�~��WH���q9�K��./�T��/3"�W��k-�8V�����`&��R
��\c��5F��?Q /���W�3���"���`�v^�ɚg2:�f?p��O�Ψ��e�q3����ǽ1?kbH B��M��רTu��r�P�Q~�/� ��Qn|x)�q©��3U_f4�6g'8�t��u��!$KGԻ�J��5 u��{�C�4y\=��&���v��U�%M�����G� �P����֪<]�3n5=1r�����
D��	(�O�g?��~?c7�����s�mxb��H���[��"ӽJ�x�:V�So�E=�-�Q|�O8
�$�쵔�)��15'���?�n{�����R�-�0�[�cA�g��}�����n��?�����I4�dLIbUVD|�h`g�5ν�J4�Z��T��X��Do�D	׳��>�!����o{�ɥ#j;G������T=��Zߗ���$����g���
��$ӭ�xqcX��H̓-���R�?���?�DݞR����5�9azɰ�D�ʶ5Q�߀"b�T��;}��u,|#�Q��5mM�%	���u'�&����Up��.B��C�?ɐh��':q����nXcd�䉪lQ��ڵ�d���Ȓ��;tMvՄ��'X���@��i��<�3ZD��g��M�MZ�&�yV埘p�D��q����ׅ���!x���{��v��/;���O^��`�C���C��,��=�u;~�׋���j��Y	���q�6]��1�zi���V ����
}Bt���i�_�Nt{�Ih.F|�tY�1�z�a�,�/e���<��UQf~OQO���*�V-7�����D$�o����yp_j<�o�<��H1Y$�{k:��8غ�.?�DiJ���֢O�4IY�J�,(U^ �^�KUU��:�R��јJ��ee�Ja;�T)l�V
�aoR��-M�<��o`%��W���s�8U4�WE�l�(��l����>}����D���s�<�T��|R��5�{f�*}&�d�=��I���{ȼ*��Y��������b��%I䉸&�-��Ua�;�U��ڪ�ڪ�ڪ�ڪ�ڪ�ڪ�ڪ�ڪ�ڪ�ڪ�ڪ�ڪ�ڪ}����۶ x  