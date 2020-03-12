import os.path
import json
import requests
from Bio import SeqIO
from multiprocessing import Pool


rule bedgraphish_to_bedgraph:
    """
    Convert the bedgraph-ish file generated by genrich into true bedgraph file.
    """
    input:
        expand("{result_dir}/genrich/{{assembly}}-{{sample}}.bdgish", **config)
    output:
        bedgraph=expand("{result_dir}/genrich/{{assembly}}-{{sample}}.bedgraph", **config)
    log:
        expand("{log_dir}/bedgraphish_to_bedgraph/{{assembly}}-{{sample}}.log", **config)
    benchmark:
        expand("{benchmark_dir}/bedgraphish_to_bedgraph/{{assembly}}-{{sample}}.log", **config)[0]
    shell:
        """
        splits=$(grep -Pno "([^\/]*)(?=\.bam)" {input})
        splits=($splits)
        lncnt=$(wc -l {input} | echo "$(grep -Po ".*(?=\ )")":)
        splits+=($lncnt)

        counter=1
        for split in "${{splits[@]::${{#splits[@]}}-1}}";
        do
            filename=$(grep -Po "(?<=:).*" <<< $split);
            if [[ $filename =~ {wildcards.sample} ]]; then
                startnr=$(grep -Po ".*(?=\:)" <<< $split);
                endnr=$(grep -Po ".*(?=\:)" <<< ${{splits[counter]}});

                lines="NR>=startnr && NR<=endnr {{ print \$1, \$2, \$3, \$4 }}"
                lines=${{lines/startnr/$((startnr + 2))}}
                lines=${{lines/endnr/$((endnr - 1))}}

                awk "$lines" {input} > {output}
            fi
            ((counter++))
        done
        """


def find_bedgraph(wildcards):
    if wildcards.peak_caller == 'genrich':
        suffix = '.bedgraph'
    elif wildcards.peak_caller == 'macs2':
        suffix = '_treat_pileup.bdg'
    else:
        suffix = '.bedgraph'

    return f"{config['result_dir']}/{wildcards.peak_caller}/{wildcards.assembly}-{wildcards.sample}{suffix}"


rule bedgraph_bigwig:
    """
    Convert a bedgraph file into a bigwig.
    """
    input:
        bedgraph=find_bedgraph,
        genome_size=expand("{genome_dir}/{{assembly}}/{{assembly}}.fa.sizes", **config)
    output:
        out=expand("{result_dir}/{{peak_caller}}/{{assembly}}-{{sample}}.bw", **config),
        tmp=temp(expand("{result_dir}/{{peak_caller}}/{{assembly}}-{{sample}}.bedgraphtmp", **config))
    log:
        expand("{log_dir}/bedgraph_bigwig/{{peak_caller}}/{{assembly}}-{{sample}}.log", **config)
    benchmark:
        expand("{benchmark_dir}/bedgraphish_to_bedgraph/{{assembly}}-{{sample}}-{{peak_caller}}.log", **config)[0]
    conda:
        "../envs/ucsc.yaml"
    shell:
        """
        awk -v OFS='\\t' '{{print $1, $2, $3, $4}}' {input.bedgraph} | sed '/experimental/d' |
        bedSort /dev/stdin {output.tmp} > {log} 2>&1;
        bedGraphToBigWig {output.tmp} {input.genome_size} {output.out} > {log} 2>&1
        """


def find_narrowpeak(wildcards):
    if 'condition' in samples and config['biological_replicates'] != 'keep':
        return expand(f"{{result_dir}}/{wildcards.peak_caller}/replicate_processed/{wildcards.assembly}-{wildcards.sample}_peaks.narrowPeak", **config)
    else:
        ftype = 'narrowPeak' if wildcards.peak_caller in ['macs2', 'genrich'] else 'gappedPeak'
        return expand(f"{{result_dir}}/{wildcards.peak_caller}/{wildcards.assembly}-{wildcards.sample}_peaks.{ftype}", **config)


rule narrowpeak_bignarrowpeak:
    """
    Convert a narrowpeak file into a bignarrowpeak file.
    """
    input:
        narrowpeak=find_narrowpeak,
        genome_size=expand("{genome_dir}/{{assembly}}/{{assembly}}.fa.sizes", **config)
    output:
        out=     expand("{result_dir}/{{peak_caller}}/{{assembly}}-{{sample}}.bigNarrowPeak", **config),
        tmp=temp(expand("{result_dir}/{{peak_caller}}/{{assembly}}-{{sample}}.tmp.narrowPeak", **config))
    log:
        expand("{log_dir}/narrowpeak_bignarrowpeak/{{peak_caller}}/{{assembly}}-{{sample}}.log", **config)
    benchmark:
        expand("{benchmark_dir}/bedgraphish_to_bedgraph/{{assembly}}-{{sample}}-{{peak_caller}}.log", **config)[0]
    conda:
        "../envs/ucsc.yaml"
    shell:
        """
        # keep first 10 columns, idr adds extra columns we do not need for our bigpeak
        cut -d$'\t' -f 1-10 {input.narrowpeak} |
        bedSort /dev/stdin {output.tmp} > {log} 2>&1;
        bedToBigBed -type=bed4+6 -as=../../schemas/bigNarrowPeak.as {output.tmp} {input.genome_size} {output.out} > {log} 2>&1
        """


def get_strandedness(wildcards):
    sample = f"{wildcards.sample}"
    if 'replicate' in samples and config.get('technical_replicates') == 'merge':
        s2 = samples[['replicate', 'strandedness']].drop_duplicates().set_index('replicate')
        strandedness = s2["strandedness"].loc[sample]
    else:
        strandedness = samples["strandedness"].loc[sample]
    return strandedness


rule bam_stranded_bigwig:
    """
    Convert a bam file into two bigwig files, one for each strand    
    """
    input:
        bam=expand("{dedup_dir}/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.bam", **config),
        bai=expand("{dedup_dir}/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.bam.bai", **config)
    output:
        forward=expand("{result_dir}/bigwigs/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.fwd.bw", **config),
        reverse=expand("{result_dir}/bigwigs/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.rev.bw", **config),
    params:
        flags=config['deeptools'],
        strandedness=get_strandedness
    wildcard_constraints:
        sorting=config['bam_sort_order'] if config.get('bam_sort_order', False) else ""
    log:
        expand("{log_dir}/bam_bigwig/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.log", **config),
    benchmark:
        expand("{benchmark_dir}/bam_bigwig/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.benchmark.txt", **config)[0]
    conda:
        "../envs/deeptools.yaml"
    threads: 20
    resources:
        deeptools_limit=1
    shell:
        """       
        direction1=forward
        direction2=reverse
        if [ {params.strandedness} == 'reverse' ]; then
            direction1=reverse
            direction2=forward
        fi
                    
        bamCoverage --bam {input.bam} --outFileName {output.forward} --filterRNAstrand $direction1 --numberOfProcessors {threads} {params.flags} --verbose >> {log} 2>&1 &&        
        bamCoverage --bam {input.bam} --outFileName {output.reverse} --filterRNAstrand $direction2 --numberOfProcessors {threads} {params.flags} --verbose >> {log} 2>&1
        """

rule bam_bigwig:
    """
    Convert a bam file into a bigwig file
    """
    input:
        bam=expand("{dedup_dir}/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.bam", **config),
        bai=expand("{dedup_dir}/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.bam.bai", **config)
    output:
        expand("{result_dir}/bigwigs/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.bw", **config)
    params:
        config['deeptools']
    wildcard_constraints:
        sorting=config['bam_sort_order'] if config.get('bam_sort_order') else ""
    log:
        expand("{log_dir}/bam_bigwig/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.log", **config),
    benchmark:
        expand("{benchmark_dir}/bam_bigwig/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.benchmark.txt", **config)[0]
    conda:
        "../envs/deeptools.yaml"
    threads: 20
    resources:
        deeptools_limit=1
    shell:
        """
        bamCoverage --bam {input.bam} --outFileName {output} --numberOfProcessors {threads} {params} --verbose >> {log} 2>&1
        """


rule twobit:
    """
    Generate a 2bit file for each assembly
    """
    input:
        expand("{genome_dir}/{{assembly}}/{{assembly}}.fa", **config)
    output:
        expand("{genome_dir}/{{assembly}}/{{assembly}}.2bit", **config)
    log:
        expand("{log_dir}/trackhub/{{assembly}}.2bit.log", **config)
    benchmark:
        expand("{benchmark_dir}/trackhub/{{assembly}}.2bit.benchmark.txt", **config)[0]
    conda:
        "../envs/ucsc.yaml"
    shell:
        "faToTwoBit {input} {output} >> {log} 2>&1"


rule gcPercent:
    """
    Generate a gc content track
    
    source: http://hgdownload.cse.ucsc.edu/goldenPath/hg19/gc5Base/
    """
    input:
        twobit = expand("{genome_dir}/{{assembly}}/{{assembly}}.2bit", **config),
        sizes  = expand("{genome_dir}/{{assembly}}/{{assembly}}.fa.sizes", **config),
    output:
        gcpcvar = temp(expand("{genome_dir}/{{assembly}}/{{assembly}}.gc5Base.wigVarStep.txt.gz", **config)),
        gcpc    =      expand("{genome_dir}/{{assembly}}/{{assembly}}.gc5Base.bw", **config),
    log:
        expand("{log_dir}/trackhub/{{assembly}}.gc5Base.log", **config)
    benchmark:
        expand("{benchmark_dir}/trackhub/{{assembly}}.gc5Base.benchmark.txt", **config)[0]
    resources:
        mem_gb=5
    conda:
        "../envs/ucsc.yaml"
    shell:
        """
        hgGcPercent -wigOut -doGaps -file=stdout -win=5 -verbose=0 {wildcards.assembly} {input.twobit} \
            | gzip > {output.gcpcvar}
        
        wigToBigWig {output.gcpcvar} {input.sizes} {output.gcpc} >> {log} 2>&1
        """


rule cytoband:
    """
    Generate a cytoband track for each assembly
    
    source: http://genomewiki.ucsc.edu/index.php/Assembly_Hubs#Cytoband_Track
    """
    input:
        genome = expand("{genome_dir}/{{assembly}}/{{assembly}}.fa", **config),
        sizes = expand("{genome_dir}/{{assembly}}/{{assembly}}.fa.sizes", **config),
    output:
        cytoband_bb = expand("{genome_dir}/{{assembly}}/cytoBandIdeo.bb", **config),
        cytoband_bd = temp(expand("{genome_dir}/{{assembly}}/cytoBandIdeo.bed", **config)),
    log:
        expand("{log_dir}/trackhub/{{assembly}}.cytoband.log", **config)
    benchmark:
        expand("{log_dir}/trackhub/{{assembly}}.cytoband.benchmark.txt", **config)[0]
    conda:
        "../envs/ucsc.yaml"
    shell:
        """
        cat {input.sizes} | bedSort /dev/stdin /dev/stdout | awk '{{print $1,0,$2,$1,"gneg"}}' > {output.cytoband_bd}

        bedToBigBed -type=bed4 {output.cytoband_bd} -as=../../schemas/cytoBand.as {input.sizes} {output.cytoband_bb} >> {log} 2>&1
        """


def get_masked_regions(contig):
    masked_regions=''

    masked_seq = str(contig.seq)
    inMasked = False
    mmEnd = 0

    length = len(masked_seq)-1
    for x in range(0, length+1):
        # mark the starting position of a softmasked region
        if masked_seq[x].islower() and inMasked == False:
            mmStart = x + 1
            inMasked = True

        # mark end position of softmasked region (can be end of contig)
        elif (not(masked_seq[x].islower()) or x == length) and inMasked == True:
            mmEnd = x
            inMasked = False

            # store softmasked region in a bed3 (chr, start, end) file
            masked_regions += contig.id + '\t' + str(mmStart) + '\t' + str(mmEnd) + '\n'

    return masked_regions


rule softmask_track_1:
    """
    Generate a track of all softmasked regions
    
    source: https://github.com/Gaius-Augustus/MakeHub/blob/master/make_hub.py
    """
    input:
        genome = expand("{genome_dir}/{{assembly}}/{{assembly}}.fa", **config),
    output:
        mask_unsorted = temp(expand("{genome_dir}/{{assembly}}/{{assembly}}_softmasking_unsorted.bed", **config)),
    log:
        expand("{log_dir}/trackhub/{{assembly}}.softmask1.log", **config)
    benchmark:
        expand("{benchmark_dir}/trackhub/{{assembly}}.softmask1.benchmark.txt", **config)[0]
    threads: 4
    resources:
        mem_gb=2
    run:
        with open(str(input.genome), "r") as genome_handle, open(str(output.mask_unsorted), "w+") as bed_handle:
            p = Pool(threads)
            # seqIO.parse returns contig data.
            # Each contig is scanned by get_masked_regions (in parallel by imap_unordered).
            # As soon as a contig is scanned, the output is yielded and written to file.
            for softmasked_regions_per_contig in p.imap_unordered(get_masked_regions, SeqIO.parse(genome_handle, "fasta")):
                bed_handle.write(softmasked_regions_per_contig)


rule softmask_track_2:
    """
    Generate a track of all softmasked regions
    
    source: https://github.com/Gaius-Augustus/MakeHub/blob/master/make_hub.py
    """
    input:
        mask_unsorted = expand("{genome_dir}/{{assembly}}/{{assembly}}_softmasking_unsorted.bed", **config),
        sizes         = expand("{genome_dir}/{{assembly}}/{{assembly}}.fa.sizes", **config),
    output:
        maskbed = temp(expand("{genome_dir}/{{assembly}}/{{assembly}}_softmasking.bed", **config)),
        mask    =      expand("{genome_dir}/{{assembly}}/{{assembly}}_softmasking.bb", **config),
    log:
        expand("{log_dir}/trackhub/{{assembly}}.softmask2.log", **config)
    benchmark:
        expand("{benchmark_dir}/trackhub/{{assembly}}.softmask2.benchmark.txt", **config)[0]
    conda:
        "../envs/ucsc.yaml"
    shell:
        """
        bedSort {input.mask_unsorted} {output.maskbed} >> {log} 2>&1
        
        bedToBigBed -type=bed3 {output.maskbed} {input.sizes} {output.mask} >> {log} 2>&1
        """


rule trackhub_index:
    """
    Generate a searchable annotation & index for each assembly
    
    source: https://genome.ucsc.edu/goldenPath/help/hubQuickStartSearch.html
    """
    input:
        sizes = expand("{genome_dir}/{{assembly}}/{{assembly}}.fa.sizes", **config),
        gtf   = expand("{genome_dir}/{{assembly}}/{{assembly}}.gtf", **config),
    output:
        genePred =       temp(expand("{genome_dir}/{{assembly}}/{{assembly}}.gp",  **config)),
        genePredbed =    temp(expand("{genome_dir}/{{assembly}}/{{assembly}}.gp.bed", **config)),
        genePredbigbed =      expand("{genome_dir}/{{assembly}}/{{assembly}}.bb",  **config),
        info =           temp(expand("{genome_dir}/{{assembly}}/info.txt",        **config)),
        indexinfo =      temp(expand("{genome_dir}/{{assembly}}/indexinfo.txt",        **config)),
        ix =                  expand("{genome_dir}/{{assembly}}/{{assembly}}.ix",  **config),
        ixx =                 expand("{genome_dir}/{{assembly}}/{{assembly}}.ixx", **config),
    log:
        expand("{log_dir}/trackhub/{{assembly}}.index.log", **config)
    benchmark:
        expand("{benchmark_dir}/trackhub/{{assembly}}.index.benchmark.txt", **config)[0]
    conda:
        "../envs/ucsc.yaml"
    shell:
        """
        # generate annotation files
        gtfToGenePred -geneNameAsName2 -genePredExt {input.gtf} {output.genePred} -infoOut={output.info} >> {log} 2>&1

        genePredToBed {output.genePred} {output.genePredbed} >> {log} 2>&1
        
        bedSort {output.genePredbed} {output.genePredbed} >> {log} 2>&1
        
        bedToBigBed -extraIndex=name {output.genePredbed} {input.sizes} {output.genePredbigbed} >> {log} 2>&1
        
        # generate searchable indexes (by 2: geneId, 8: proteinID, 9: geneName, 10: transcriptName and 1: transcriptID)
        grep -v "^#" {output.info} | awk '{{print $1, $2, $8, $9, $10, $1}}' > {output.indexinfo}

        ixIxx {output.indexinfo} {output.ix} {output.ixx} >> {log} 2>&1
        """


def get_bigwig_strand(sample):
    """
    return a list of extensions for (un)stranded bigwigs
    """
    if 'strandedness' in samples and config['filter_bam_by_strand']:
        if 'replicate' in samples and config.get('technical_replicates') == 'merge':
            s2 = samples[['replicate', 'strandedness']].drop_duplicates().set_index('replicate')
            strandedness = s2["strandedness"].loc[sample]
            if strandedness in ['forward', 'yes', 'reverse']:
                return ['.fwd', '.rev']
        else:
            strandedness = samples["strandedness"].loc[sample]
            if strandedness in ['forward', 'yes', 'reverse']:
                return ['.fwd', '.rev']
    return ['']


def get_ucsc_name(assembly):
    """
    Returns as first value (bool) whether or not the assembly was found to be in the
    ucsc genome browser, and as second value the name of the assembly according to ucsc
    "convention".
    """
    with urllib.request.urlopen("https://api.genome.ucsc.edu/list/ucscGenomes") as url:
        data = json.loads(url.read().decode())['ucscGenomes']

    # patches are not relevant for which assembly it belongs to
    # (at least not human and mouse)
    assembly_np = \
        [split for split in re.split(r"(.+)(?=\.p\d)", assembly) if split != ''][0].lower()

    # first check if our assembly already has the ucsc convention
    # this is ugly, because we need to be case insensitive
    ucsc_assemblies = [key.lower() for key in data.keys()]
    if assembly_np in ucsc_assemblies:
        idx = ucsc_assemblies.index(assembly_np)
        return True, list(data.keys())[idx]

    # else check if it is in any of the other names
    for ucsc_assembly, values in data.items():
        desc = values['description']
        assemblies = desc[desc.find("(")+1:desc.find(")")].split("/")
        assemblies = [val.lower() for val in assemblies]
        if assembly_np in assemblies:
            return True, ucsc_assembly

    # if not found, return the original name
    return False, assembly


def get_trackhub_files(wildcards):
    """
    Assemble all files used in a trackhub/assembly hub.

    If an assembly hub already exist for an assembly, only list trackhub files.

    Includes assembly hub files, annotation dependent assembly hub files and workflow dependent files.
    """
    trackfiles = {key: [] for key in ['bigwigs', 'bigpeaks', 'twobits', 'gcPercent', 'cytobands', 'RMsoft', 'annotations']}

    # check whether or not each assembly is supported by ucsc
    for assembly in set(samples['assembly']):
        # first, checks if get_genome still needs to run
        # second, checks if an annotation file was found
        # TODO: use next 2 lines again when checkpoints are stable
        #  1) does the trackhub input update? 2) does ruleorder work?
        # f = os.path.splitext(checkpoints.get_genome.get(assembly=assembly).output[0])[0]
        # gtf = any([os.path.isfile(f+".annotation.gtf"), os.path.isfile(f+".gtf")])
        gtf = True if get_workflow() == 'rna_seq' else False

        # check for response of ucsc
        response = requests.get(f"https://genome.ucsc.edu/cgi-bin/hgTracks?db={assembly}",
                                allow_redirects=True)
        assert response.ok, "Make sure you are connected to the internet"

        # see if the title of the page mentions our assembly
        if not get_ucsc_name(assembly)[0]:
            trackfiles['twobits'].append(f"{config['genome_dir']}/{assembly}/{assembly}.2bit")
            trackfiles['gcPercent'].append(f"{config['genome_dir']}/{assembly}/{assembly}.gc5Base.bw")
            trackfiles['cytobands'].append(f"{config['genome_dir']}/{assembly}/cytoBandIdeo.bb")
            trackfiles['RMsoft'].append(f"{config['genome_dir']}/{assembly}/{assembly}_softmasking.bb")

            # add gtf-dependent file(s) only if the gtf has been found
            if gtf:
                trackfiles['annotations'].append(f"{config['genome_dir']}/{assembly}/{assembly}.bb")

    # Get the ATAC or RNA seq files
    if get_workflow() == 'atac_seq':
        # get all the peak files
        for sample in breps.index:
            trackfiles['bigpeaks'].extend(expand(f"{{result_dir}}/{{peak_caller}}/{breps.loc[sample, 'assembly']}-{sample}.bigNarrowPeak", **config))

        # get all the bigwigs
        for sample in treps.index:
            trackfiles['bigwigs'].extend(expand(f"{{result_dir}}/{{peak_caller}}/{treps.loc[sample, 'assembly']}-{sample}.bw", **config))

    elif get_workflow() in ['alignment', 'rna_seq']:
        # get all the bigwigs
        for sample in treps.index:
            for bw in get_bigwig_strand(sample):
                bw = expand(f"{{result_dir}}/bigwigs/{treps.loc[sample]['assembly']}-{sample}.{config['bam_sorter']}-{config['bam_sort_order']}{bw}.bw", **config)
                trackfiles['bigwigs'].extend(bw)

    return trackfiles


def get_defaultPos(sizefile):
    # extract a default position spanning the first scaffold/chromosome in the sizefile.
    with open(sizefile, 'r') as file:
        dflt = file.readline().strip('\n').split('\t')
    return dflt[0] + ':0-' + str(min(int(dflt[1]), 100000))


rule trackhub:
    """
    Generate a trackhub which has to be hosted on an internet accessible location, 
    but can then be viewed through the UCSC genome browser.
    """
    input:
        unpack(get_trackhub_files)
    output:
        directory(f"{config['result_dir']}/trackhub")
    log:
        expand("{log_dir}/trackhub/trackhub.log", **config)
    benchmark:
        expand("{benchmark_dir}/trackhub/trackhub.benchmark.txt", **config)[0]
    run:
        import re
        import sys
        import trackhub

        with open(log[0], 'w') as f:
            sys.stderr = sys.stdout = f
            orderkey = 4800

            # start a shared hub
            hub = trackhub.Hub(
                hub        =config.get('hubname',    'trackhub'),
                short_label=config.get('shortlabel', 'trackhub'), # 17 characters max
                long_label =config.get('longlabel',  "Automated trackhub generated by the snakemake-workflows tool: \n"
                                                     "https://github.com/vanheeringen-lab/snakemake-workflows"),
                email      =config.get('email',      'none@provided.com'))

            # link the genomes file to the hub
            genomes_file = trackhub.genomes_file.GenomesFile()
            hub.add_genomes_file(genomes_file)

            for assembly in set(samples['assembly']):
                assembly_uscs = get_ucsc_name(assembly)[1]
                # add each assembly to the genomes file
                if any(assembly in twobit for twobit in input.twobits):
                    basename = f"{config['genome_dir']}/{assembly}/{assembly}"
                    genome = trackhub.Assembly(
                        genome=assembly_uscs,
                        twobit_file=basename + '.2bit',
                        organism=assembly,
                        defaultPos=get_defaultPos(basename + '.fa.sizes'),
                        scientificName=assembly,
                        description=assembly
                    )
                else:
                    genome = trackhub.Genome(assembly_uscs)

                genomes_file.add_genome(genome)

                # each trackdb is added to the genome
                trackdb = trackhub.trackdb.TrackDb()
                genome.add_trackdb(trackdb)
                # order tracks in the browser. 1-4 are used for annotation files
                priority = 5

                # add annotation files
                for file in input:
                    if assembly in file:

                        if "cytoBand" in file:
                            track = trackhub.Track(
                                name='cytoBandIdeo',
                                source=file,
                                tracktype='bigBed',
                                visibility='dense',
                                color='0,0,0', # black
                                priority=1,
                            )
                            trackdb.add_tracks(track)

                        elif "gc5Base" in file:
                            track = trackhub.Track(
                                name='gcPercent',
                                source=file,
                                tracktype='bigWig',
                                visibility='dense',
                                color='59,189,191', # cyan
                                priority=3,
                            )
                            trackdb.add_tracks(track)

                        elif "softmasking" in file:
                            track = trackhub.Track(
                                name='softmasked',
                                source=file,
                                tracktype='bigBed',
                                visibility='dense',
                                color='128,128,128', # grey
                                priority=4,
                            )
                            trackdb.add_tracks(track)

                        elif assembly + ".bb" in file:
                            track = trackhub.Track(
                                name='annotation',
                                source=file,
                                tracktype='bigBed',
                                visibility='pack',
                                color='140,43,69', # bourgundy
                                priority=2,
                                searchIndex="name",
                                searchTrix=assembly + ".ix",
                            )
                            trackdb.add_tracks(track)

                            # copy the trix files (requires the directory to exist)
                            dir = os.path.join(str(output), assembly)
                            shell(f"mkdir -p {dir}")
                            for ext in ['.ix', '.ixx']:
                                file_loc = basename + ext
                                link_loc = os.path.join(dir, assembly + ext)
                                shell(f"ln {file_loc} {link_loc}")

                # next add the data files depending on the workflow
                # ATAC-seq trackhub
                if 'atac_seq' in get_workflow():
                    for peak_caller in config['peak_caller']:
                        for sample in breps[breps['assembly'] == assembly].index:
                            bigpeak = f"{config['result_dir']}/{peak_caller}/{assembly}-{sample}.bigNarrowPeak"
                            sample_name = f"{sample}{peak_caller}PEAK"
                            sample_name = trackhub.helpers.sanitize(sample_name)

                            if bigpeak:
                                track = trackhub.Track(
                                    name=sample_name,           # track names can't have any spaces or special chars.
                                    source=bigpeak,             # filename to build this track from
                                    visibility='dense',         # shows the full signal
                                    tracktype='bigNarrowPeak',  # required when making a track
                                    priority=priority
                                )
                                priority += 1
                                trackdb.add_tracks(track)

                        for sample in treps[treps['assembly'] == assembly].index:
                            bigwig = f"{config['result_dir']}/{peak_caller}/{assembly}-{sample}.bw"
                            assert os.path.exists(bigwig), bigwig + " not found!"
                            sample_name = f"{sample}{peak_caller}BW"
                            sample_name = trackhub.helpers.sanitize(sample_name)

                            track = trackhub.Track(
                                name=sample_name,    # track names can't have any spaces or special chars.
                                source=bigwig,       # filename to build this track from
                                visibility='full',   # shows the full signal
                                color='0,0,0',       # black
                                autoScale='on',      # allow the track to autoscale
                                tracktype='bigWig',  # required when making a track
                                priority=priority,
                                maxHeightPixels='100:32:8'
                            )

                            # each track is added to the trackdb
                            trackdb.add_tracks(track)
                            priority += 1

                # RNA-seq trackhub
                elif get_workflow() in ['alignment', 'rna_seq']:
                    for sample in treps[treps['assembly'] == assembly].index:
                        for bw in get_bigwig_strand(sample):
                            bigwig = f"{config['result_dir']}/bigwigs/{assembly}-{sample}.{config['bam_sorter']}-{config['bam_sort_order']}{bw}.bw"
                            assert os.path.exists(bigwig), bigwig + " not found!"
                            sample_name = f"{sample}{bw}"
                            sample_name = trackhub.helpers.sanitize(sample_name)

                            track = trackhub.Track(
                                name=sample_name,    # track names can't have any spaces or special chars.
                                source=bigwig,       # filename to build this track from
                                visibility='full',   # shows the full signal
                                color='0,0,0',       # black
                                autoScale='on',      # allow the track to autoscale
                                tracktype='bigWig',  # required when making a track
                                priority=priority,
                                maxHeightPixels='100:32:8'
                            )

                            # each track is added to the trackdb
                            trackdb.add_tracks(track)
                            priority += 1

            # now finish by storing the result
            trackhub.upload.upload_hub(hub=hub, host='localhost', remote_dir=output[0])
