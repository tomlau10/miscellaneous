#!/bin/bash
# 
# Simulate multiple threads downloading by forking many process
# Copyright 2016 Wanghong Lin 
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
# 	http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# 
# 
# Changelog
# v0.1        initial version
# v0.1.1      add output option

slices=20

case $OSTYPE in
    *linux*) slices=$(grep -c processor /proc/cpuinfo) ;;
    *darwin*) slices=$(sysctl hw.ncpu | cut -d' ' -f2) ;;
    *cygwin*) slices=$NUMBER_OF_PROCESSORS ;;
    *) slices=20 ;;
esac

url=
output=
force=0
curl_opts=()

__ScriptVersion="v0.1.1"

#===  FUNCTION  ================================================================
#         NAME:  usage
#  DESCRIPTION:  Display usage information.
#===============================================================================
function usage ()
{
    echo "Usage :  $0 [options] url [curl options]

    Options:
    -h|help       Display this message
    -v|version    Display script version
    -s|slice      How many slices the download task will split, default is $slices
    -o|output     Specify the output file name, use the guessing file name from url as output file name if not specify this option
    -f|force      Force overwirte output file if exists

    Anything after 'url' will be passed to curl as curl options"

}    # ----------  end of function usage  ----------

#-----------------------------------------------------------------------
#  Handle command line arguments
#-----------------------------------------------------------------------

while getopts ":hv:s:o:f" opt
do
    case $opt in
	h|help     )  usage; exit 0   ;;
	v|version  )  echo "Multi tasks downloader for curl, version $__ScriptVersion"; exit 0   ;;
	s|slice    )  slices=$OPTARG ;;
	o|output   )  output=$OPTARG ;;
	f|force    )  force=1 ;;
	* )  echo -e "\n  Option does not exist : $OPTARG\n"
	    usage; exit 1   ;;
    esac    # --- end of case ---
done
shift $(($OPTIND-1))

url=$1

if ! [[ $url =~ ^https?://.*$ ]];then
    printf "\e[31mInvalid URL $url\e[0m\n"
    usage
    exit 1
fi

# get curl options
curl_opts=("${@:2}")
if [ "${#curl_opts[@]}" -gt 0 ] && [[ "${curl_opts[0]}" != "-"* ]]; then
	printf "\e[31mCurl options are expected after URL param\e[0m\n"
	usage
	exit 1
fi

url_no_query=${url%%\?*}
file_to_save=${url_no_query##*/}

[ x$output != x ] && file_to_save=$output

echo "Download $url to $file_to_save with $slices tasks."

size_in_byte=$(curl "${curl_opts[@]}" -I "$url" 2>/dev/null | sed -n 's/\([Cc]ontent-[Ll]ength:\)\(.*\)/\2/p' | tr -d [[:space:]])

if ! [[ $size_in_byte =~ ^[0-9]+$ ]];then
    printf "\e[31mCould not get content length, make sure your resource have content length response.\e[0m\n"
    exit 1
fi

# check if target file exist
if [ -f "$file_to_save" ]; then
	if (( $force )); then
		rm -f "$file_to_save" || exit 1
	else
		# prompt to delete file
		echo "Target file already exists!"
		rm -i "$file_to_save" || exit 1
		[ -f "$file_to_save" ] && echo "Cancelled" && exit
	fi
fi

# remove temp files and kill all sub processes if exit early
function exit_cleanup()
{
	rm -rf $$.*
	# remove SIGTERM handler then kill the whole process group
	trap - SIGTERM
	kill -s SIGTERM -- -$$
}
trap exit_cleanup SIGINT SIGTERM SIGQUIT

size_per_slice=$(($size_in_byte/$slices))
let size_per_slice=${size_per_slice}+1  # avoid rounding issue

total_slice=${slices}
function callback()
{
	subp=$(pgrep -P $$ | wc -l)
	if [  $subp -eq 1 ];then
		printf "\rProgress 100%%\n"
		for s in `seq $total_slice`
		do
			printf "\rMerging slices [$s/$total_slice]"
			cat $$.$s >> "${file_to_save}"
			rm $$.$s
		done
		echo
		echo "Done in $((`date +%s`-$start_time))s"
		exit
	fi
}

function run()
{
	curl "${curl_opts[@]}" -r $2-$3 $url -o $1 2>/dev/null && kill -n 10 $$ &
}

trap callback 10

printf "\rProgress   0%%"
start_time=$(date +%s)
for s in `seq $total_slice`
do
	begin=$((($s-1)*${size_per_slice}))
	if [ $begin -ne 0 ];then
		begin=$((begin+=1))
	fi
	end=$(($s*$size_per_slice))
	if [ $end -gt $size_in_byte ];then
		end=
	fi
	run $$.$s $begin $end
done

while :
do
	if [ -f $$.1 ];then
		total_byte=$(wc -c $$.* | awk 'END{print $1}')
		duration=$((`date +%s`-$start_time))
		[ $duration -gt 0 ] && printf "\r\e[KProgress %3d%%; Current average speed %4d KiB/s" $(($total_byte*100/$size_in_byte)) $(($total_byte/1024/$duration))
	fi
	sleep 1
done
