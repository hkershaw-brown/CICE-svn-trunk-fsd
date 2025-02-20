
!  SVN:$Id: ice_restart.F90 607 2013-03-29 15:49:42Z eclare $
!=======================================================================
!
! Read and write ice model restart files using pio interfaces.
! authors David A Bailey, NCAR

      module ice_restart

      use ice_broadcast
      use ice_exit, only: abort_ice
      use ice_kinds_mod
      use ice_restart_shared, only: &
          restart, restart_ext, restart_dir, restart_file, pointer_file, &
          runid, runtype, use_restart_time, restart_format, lcdf64, lenstr
      use ice_pio
      use pio

      implicit none
      private
      public :: init_restart_write, init_restart_read, &
                read_restart_field, write_restart_field, final_restart
      save

      type(file_desc_t)     :: File
      type(var_desc_t)      :: vardesc

      type(io_desc_t)       :: iodesc2d
      type(io_desc_t)       :: iodesc3d_ncat

!=======================================================================

      contains

!=======================================================================

! Sets up restart file for reading.
! author David A Bailey, NCAR

      subroutine init_restart_read(ice_ic)

      use ice_calendar, only: istep0, istep1, time, time_forc, nyr, month, &
          mday, sec, npt
      use ice_communicate, only: my_task, master_task
      use ice_domain_size, only: ncat
      use ice_fileunits, only: nu_diag, nu_restart, nu_rst_pointer
      use ice_read_write, only: ice_open

      character(len=char_len_long), intent(in), optional :: ice_ic

      ! local variables

      character(len=char_len_long) :: &
         filename, filename0

      integer (kind=int_kind) :: status

      if (present(ice_ic)) then 
         filename = trim(ice_ic)
      else
         if (my_task == master_task) then
            open(nu_rst_pointer,file=pointer_file)
            read(nu_rst_pointer,'(a)') filename0
            filename = trim(filename0)
            close(nu_rst_pointer)
            write(nu_diag,*) 'Read ',pointer_file(1:lenstr(pointer_file))
         endif
         call broadcast_scalar(filename, master_task)
      endif

      if (my_task == master_task) then
         write(nu_diag,*) 'Using restart dump=', trim(filename)
      end if

      if (restart_format == 'pio') then
         File%fh=-1
         call ice_pio_init(mode='read', filename=trim(filename), File=File)
      
         call ice_pio_initdecomp(iodesc=iodesc2d)
         call ice_pio_initdecomp(ndim3=ncat  , iodesc=iodesc3d_ncat,remap=.true.)

         if (use_restart_time) then
         status = pio_get_att(File, pio_global, 'istep1', istep0)
         status = pio_get_att(File, pio_global, 'time', time)
         status = pio_get_att(File, pio_global, 'time_forc', time_forc)
         call pio_seterrorhandling(File, PIO_BCAST_ERROR)
         status = pio_get_att(File, pio_global, 'nyr', nyr)
         call pio_seterrorhandling(File, PIO_INTERNAL_ERROR)
         if (status == PIO_noerr) then
            status = pio_get_att(File, pio_global, 'month', month)
            status = pio_get_att(File, pio_global, 'mday', mday)
            status = pio_get_att(File, pio_global, 'sec', sec)
         endif
         endif ! use namelist values if use_restart_time = F
      endif

      if (my_task == master_task) then
         write(nu_diag,*) 'Restart read at istep=',istep0,time,time_forc
      endif

      call broadcast_scalar(istep0,master_task)
      call broadcast_scalar(time,master_task)
      call broadcast_scalar(time_forc,master_task)
      
      istep1 = istep0

      ! if runid is bering then need to correct npt for istep0
      if (trim(runid) == 'bering') then
         npt = npt - istep0
      endif

      end subroutine init_restart_read

!=======================================================================

! Sets up restart file for writing.
! author David A Bailey, NCAR

      subroutine init_restart_write(filename_spec)

      use ice_calendar, only: sec, month, mday, nyr, istep1, &
                              time, time_forc, year_init
      use ice_communicate, only: my_task, master_task
      use ice_domain_size, only: nx_global, ny_global, ncat, nilyr, nslyr, &
                                 n_aero
      use ice_dyn_shared, only: kdyn
      use ice_fileunits, only: nu_diag, nu_rst_pointer
      use ice_ocean, only: oceanmixed_ice
      use ice_state, only: tr_iage, tr_FY, tr_lvl, tr_aero, tr_pond_cesm, &
                           tr_pond_topo, tr_pond_lvl, tr_brine
      use ice_zbgc_shared, only: tr_bgc_N_sk, tr_bgc_C_sk, tr_bgc_Nit_sk, &
                           tr_bgc_Sil_sk, tr_bgc_DMSPp_sk, tr_bgc_DMS_sk, &
                           tr_bgc_chl_sk, tr_bgc_DMSPd_sk, tr_bgc_Am_sk, &
                           skl_bgc

      character(len=char_len_long), intent(in), optional :: filename_spec

      ! local variables

      integer (kind=int_kind) :: &
          iyear, imonth, iday     ! year, month, day

      character(len=char_len_long) :: filename

      integer (kind=int_kind) :: dimid_ni, dimid_nj, dimid_ncat, &
                                 dimid_nilyr, dimid_nslyr, dimid_naero

      integer (kind=int_kind), allocatable :: dims(:)

      integer (kind=int_kind) :: &
        k         , & ! loop index
        status        ! status variable from netCDF routine

      character (len=3) :: nchar

      ! construct path/file
      if (present(filename_spec)) then
         filename = trim(filename_spec)
      else
         iyear = nyr + year_init - 1
         imonth = month
         iday = mday
      
         write(filename,'(a,a,a,i4.4,a,i2.2,a,i2.2,a,i5.5)') &
              restart_dir(1:lenstr(restart_dir)), &
              restart_file(1:lenstr(restart_file)),'.', &
              iyear,'-',month,'-',mday,'-',sec
      end if
        
      if (restart_format /= 'bin') filename = trim(filename) // '.nc'

      ! write pointer (path/file)
      if (my_task == master_task) then
         open(nu_rst_pointer,file=pointer_file)
         write(nu_rst_pointer,'(a)') filename
         close(nu_rst_pointer)
      endif

      if (restart_format == 'pio') then
      
         File%fh=-1
         call ice_pio_init(mode='write',filename=trim(filename), File=File, &
              clobber=.true., cdf64=lcdf64 )

         status = pio_put_att(File,pio_global,'istep1',istep1)
         status = pio_put_att(File,pio_global,'time',time)
         status = pio_put_att(File,pio_global,'time_forc',time_forc)
         status = pio_put_att(File,pio_global,'nyr',nyr)
         status = pio_put_att(File,pio_global,'month',month)
         status = pio_put_att(File,pio_global,'mday',mday)
         status = pio_put_att(File,pio_global,'sec',sec)

         status = pio_def_dim(File,'ni',nx_global,dimid_ni)
         status = pio_def_dim(File,'nj',ny_global,dimid_nj)
         status = pio_def_dim(File,'ncat',ncat,dimid_ncat)

      !-----------------------------------------------------------------
      ! 2D restart fields
      !-----------------------------------------------------------------

         allocate(dims(2))

         dims(1) = dimid_ni
         dims(2) = dimid_nj

         call define_rest_field(File,'uvel',dims)
         call define_rest_field(File,'vvel',dims)

#ifdef CESMCOUPLED
         call define_rest_field(File,'coszen',dims)
#endif
         call define_rest_field(File,'scale_factor',dims)
         call define_rest_field(File,'swvdr',dims)
         call define_rest_field(File,'swvdf',dims)
         call define_rest_field(File,'swidr',dims)
         call define_rest_field(File,'swidf',dims)

         call define_rest_field(File,'strocnxT',dims)
         call define_rest_field(File,'strocnyT',dims)

         call define_rest_field(File,'stressp_1',dims)
         call define_rest_field(File,'stressp_2',dims)
         call define_rest_field(File,'stressp_3',dims)
         call define_rest_field(File,'stressp_4',dims)

         call define_rest_field(File,'stressm_1',dims)
         call define_rest_field(File,'stressm_2',dims)
         call define_rest_field(File,'stressm_3',dims)
         call define_rest_field(File,'stressm_4',dims)

         call define_rest_field(File,'stress12_1',dims)
         call define_rest_field(File,'stress12_2',dims)
         call define_rest_field(File,'stress12_3',dims)
         call define_rest_field(File,'stress12_4',dims)

         call define_rest_field(File,'iceumask',dims)

         if (oceanmixed_ice) then
            call define_rest_field(File,'sst',dims)
            call define_rest_field(File,'frzmlt',dims)
         endif

         if (tr_FY) then
            call define_rest_field(File,'frz_onset',dims)
         end if

         if (kdyn == 2) then
            call define_rest_field(File,'a11_1',dims)
            call define_rest_field(File,'a11_2',dims)
            call define_rest_field(File,'a11_3',dims)
            call define_rest_field(File,'a11_4',dims)
            call define_rest_field(File,'a12_1',dims)
            call define_rest_field(File,'a12_2',dims)
            call define_rest_field(File,'a12_3',dims)
            call define_rest_field(File,'a12_4',dims)
         endif

         if (tr_pond_lvl) then
            call define_rest_field(File,'fsnow',dims)
         endif

         if (skl_bgc) then
            call define_rest_field(File,'algalN',dims)
            call define_rest_field(File,'nit'   ,dims)
            if (tr_bgc_Am_sk) &
            call define_rest_field(File,'amm'   ,dims)
            if (tr_bgc_Sil_sk) &
            call define_rest_field(File,'sil'   ,dims)
            if (tr_bgc_DMSPp_sk) &
            call define_rest_field(File,'dmsp'  ,dims)
            if (tr_bgc_DMS_sk) &
            call define_rest_field(File,'dms'   ,dims)
         endif

         deallocate(dims)

      !-----------------------------------------------------------------
      ! 3D restart fields (ncat)
      !-----------------------------------------------------------------

         allocate(dims(3))

         dims(1) = dimid_ni
         dims(2) = dimid_nj
         dims(3) = dimid_ncat

         call define_rest_field(File,'aicen',dims)
         call define_rest_field(File,'vicen',dims)
         call define_rest_field(File,'vsnon',dims)
         call define_rest_field(File,'Tsfcn',dims)

         if (tr_iage) then
            call define_rest_field(File,'iage',dims)
         end if

         if (tr_FY) then
            call define_rest_field(File,'FY',dims)
         end if

         if (tr_lvl) then
            call define_rest_field(File,'alvl',dims)
            call define_rest_field(File,'vlvl',dims)
         end if

         if (tr_pond_cesm) then
            call define_rest_field(File,'apnd',dims)
            call define_rest_field(File,'hpnd',dims)
         end if

         if (tr_pond_topo) then
            call define_rest_field(File,'apnd',dims)
            call define_rest_field(File,'hpnd',dims)
            call define_rest_field(File,'ipnd',dims)
         end if

         if (tr_pond_lvl) then
            call define_rest_field(File,'apnd',dims)
            call define_rest_field(File,'hpnd',dims)
            call define_rest_field(File,'ipnd',dims)
            call define_rest_field(File,'dhs',dims)
            call define_rest_field(File,'ffrac',dims)
         end if

         if (tr_brine) then
            call define_rest_field(File,'fbrn',dims)
            call define_rest_field(File,'first_ice',dims)
         endif

         if (skl_bgc) then
            call define_rest_field(File,'bgc_N_sk'    ,dims)
            call define_rest_field(File,'bgc_Nit_sk'  ,dims)
            if (tr_bgc_C_sk) &
            call define_rest_field(File,'bgc_C_sk'    ,dims)
            if (tr_bgc_chl_sk) &
            call define_rest_field(File,'bgc_chl_sk'  ,dims)
            if (tr_bgc_Am_sk) &
            call define_rest_field(File,'bgc_Am_sk'   ,dims)
            if (tr_bgc_Sil_sk) &
            call define_rest_field(File,'bgc_Sil_sk'  ,dims)
            if (tr_bgc_DMSPp_sk) &
            call define_rest_field(File,'bgc_DMSPp_sk',dims)
            if (tr_bgc_DMSPd_sk) &
            call define_rest_field(File,'bgc_DMSPd_sk',dims)
            if (tr_bgc_DMS_sk) &
            call define_rest_field(File,'bgc_DMS_sk'  ,dims)
         endif

      !-----------------------------------------------------------------
      ! 4D restart fields, written as layers of 3D
      !-----------------------------------------------------------------

         do k=1,nilyr
            write(nchar,'(i3.3)') k
            call define_rest_field(File,'sice'//trim(nchar),dims)
            call define_rest_field(File,'qice'//trim(nchar),dims)
         enddo

         do k=1,nslyr
            write(nchar,'(i3.3)') k
            call define_rest_field(File,'qsno'//trim(nchar),dims)
         enddo

         if (tr_aero) then
            do k=1,n_aero
               write(nchar,'(i3.3)') k
               call define_rest_field(File,'aerosnossl'//nchar, dims)
               call define_rest_field(File,'aerosnoint'//nchar, dims)
               call define_rest_field(File,'aeroicessl'//nchar, dims)
               call define_rest_field(File,'aeroiceint'//nchar, dims)
            enddo
         endif

         deallocate(dims)
         status = pio_enddef(File)

         call ice_pio_initdecomp(iodesc=iodesc2d)
         call ice_pio_initdecomp(ndim3=ncat  , iodesc=iodesc3d_ncat, remap=.true.)

      endif

      if (my_task == master_task) then
         write(nu_diag,*) 'Writing ',filename(1:lenstr(filename))
      endif

      end subroutine init_restart_write

!=======================================================================

! Reads a single restart field
! author David A Bailey, NCAR

      subroutine read_restart_field(nu,nrec,work,atype,vname,ndim3,diag, &
                                    field_loc, field_type)

      use ice_blocks, only: nx_block, ny_block
      use ice_communicate, only: my_task, master_task
      use ice_constants, only: c0, field_loc_center
      use ice_boundary, only: ice_HaloUpdate
      use ice_domain, only: halo_info, distrb_info, nblocks
      use ice_domain_size, only: max_blocks, ncat
      use ice_fileunits, only: nu_diag
      use ice_global_reductions, only: global_minval, global_maxval, global_sum

      integer (kind=int_kind), intent(in) :: &
           nu            , & ! unit number (not used for netcdf)
           ndim3         , & ! third dimension
           nrec              ! record number (0 for sequential access)

      real (kind=dbl_kind), dimension(nx_block,ny_block,ndim3,max_blocks), &
           intent(inout) :: &
           work              ! input array (real, 8-byte)

      character (len=4), intent(in) :: &
           atype             ! format for output array
                             ! (real/integer, 4-byte/8-byte)

      logical (kind=log_kind), intent(in) :: &
           diag              ! if true, write diagnostic output

      character (len=*), intent(in)  :: vname

      integer (kind=int_kind), optional, intent(in) :: &
           field_loc, &      ! location of field on staggered grid
           field_type        ! type of field (scalar, vector, angle)

      ! local variables

      integer (kind=int_kind) :: &
        j,     &      ! dimension counter
        n,     &      ! number of dimensions for variable
        status        ! status variable from netCDF routine

      real (kind=dbl_kind) :: amin,amax,asum

      if (restart_format == "pio") then
         if (my_task == master_task) &
            write(nu_diag,*)'Parallel restart file read: ',vname

         call pio_seterrorhandling(File, PIO_BCAST_ERROR)

         status = pio_inq_varid(File,trim(vname),vardesc)

         if (status /= 0) then
            call abort_ice("CICE4 restart? Missing variable: "//trim(vname))
         endif

         call pio_seterrorhandling(File, PIO_INTERNAL_ERROR)

         if (ndim3 == ncat .and. ncat>1) then
            call pio_read_darray(File, vardesc, iodesc3d_ncat, work, status)
            if (present(field_loc)) then
               do n=1,ndim3
                  call ice_HaloUpdate (work(:,:,n,:), halo_info, &
                                       field_loc, field_type)
               enddo
            endif
         elseif (ndim3 == 1) then
            call pio_read_darray(File, vardesc, iodesc2d, work, status)
            if (present(field_loc)) then
               call ice_HaloUpdate (work(:,:,1,:), halo_info, &
                                    field_loc, field_type)
            endif
         else
            write(nu_diag,*) "ndim3 not supported ",ndim3
         endif

         if (diag) then
            if (ndim3 > 1) then
               do n=1,ndim3
                  amin = global_minval(work(:,:,n,:),distrb_info)
                  amax = global_maxval(work(:,:,n,:),distrb_info)
                  asum = global_sum(work(:,:,n,:), distrb_info, field_loc_center)
                  if (my_task == master_task) then
                     write(nu_diag,*) ' min and max =', amin, amax
                     write(nu_diag,*) ' sum =',asum
                  endif
               enddo
            else
               amin = global_minval(work(:,:,1,:),distrb_info)
               amax = global_maxval(work(:,:,1,:),distrb_info)
               asum = global_sum(work(:,:,1,:), distrb_info, field_loc_center)
               if (my_task == master_task) then
                  write(nu_diag,*) ' min and max =', amin, amax
                  write(nu_diag,*) ' sum =',asum
                  write(nu_diag,*) ''
               endif
            endif
         
         endif
      else
         call abort_ice("Invalid restart_format: "//restart_format)
      endif

      end subroutine read_restart_field
      
!=======================================================================

! Writes a single restart field.
! author David A Bailey, NCAR

      subroutine write_restart_field(nu,nrec,work,atype,vname,ndim3,diag)

      use ice_blocks, only: nx_block, ny_block
      use ice_communicate, only: my_task, master_task
      use ice_constants, only: c0, field_loc_center
      use ice_domain, only: distrb_info, nblocks
      use ice_domain_size, only: max_blocks, ncat
      use ice_fileunits, only: nu_diag
      use ice_global_reductions, only: global_minval, global_maxval, global_sum

      integer (kind=int_kind), intent(in) :: &
           nu            , & ! unit number
           ndim3         , & ! third dimension
           nrec              ! record number (0 for sequential access)

      real (kind=dbl_kind), dimension(nx_block,ny_block,ndim3,max_blocks), &
           intent(in) :: &
           work              ! input array (real, 8-byte)

      character (len=4), intent(in) :: &
           atype             ! format for output array
                             ! (real/integer, 4-byte/8-byte)

      logical (kind=log_kind), intent(in) :: &
           diag              ! if true, write diagnostic output

      character (len=*), intent(in)  :: vname

      ! local variables

      integer (kind=int_kind) :: &
        j,     &      ! dimension counter
        n,     &      ! dimension counter
        ndims, &  ! number of variable dimensions
        status        ! status variable from netCDF routine

      real (kind=dbl_kind) :: amin,amax,asum

      if (restart_format == "pio") then
         if (my_task == master_task) &
            write(nu_diag,*)'Parallel restart file write: ',vname

         status = pio_inq_varid(File,trim(vname),vardesc)
         
         status = pio_inq_varndims(File, vardesc, ndims)

         if (ndims==3) then 
            call pio_write_darray(File, vardesc, iodesc3d_ncat,work(:,:,:,1:nblocks), &
                 status, fillval=c0)
         elseif (ndims == 2) then
            call pio_write_darray(File, vardesc, iodesc2d, work(:,:,1,1:nblocks), &
                 status, fillval=c0)
         else
            write(nu_diag,*) "ndims not supported",ndims,ndim3
         endif

         if (diag) then
            if (ndim3 > 1) then
               do n=1,ndim3
                  amin = global_minval(work(:,:,n,:),distrb_info)
                  amax = global_maxval(work(:,:,n,:),distrb_info)
                  asum = global_sum(work(:,:,n,:), distrb_info, field_loc_center)
                  if (my_task == master_task) then
                     write(nu_diag,*) ' min and max =', amin, amax
                     write(nu_diag,*) ' sum =',asum
                  endif
               enddo
            else
               amin = global_minval(work(:,:,1,:),distrb_info)
               amax = global_maxval(work(:,:,1,:),distrb_info)
               asum = global_sum(work(:,:,1,:), distrb_info, field_loc_center)
               if (my_task == master_task) then
                  write(nu_diag,*) ' min and max =', amin, amax
                  write(nu_diag,*) ' sum =',asum
               endif
            endif
         endif
      else
         call abort_ice("Invalid restart_format: "//restart_format)
      endif

      end subroutine write_restart_field

!=======================================================================

! Finalize the restart file.
! author David A Bailey, NCAR

      subroutine final_restart()

      use ice_calendar, only: istep1, time, time_forc
      use ice_communicate, only: my_task, master_task
      use ice_fileunits, only: nu_diag

      if (restart_format == 'pio') then
         call PIO_freeDecomp(File,iodesc2d)
         call PIO_freeDecomp(File,iodesc3d_ncat)
         call pio_closefile(File)
      endif

      if (my_task == master_task) &
         write(nu_diag,*) 'Restart read/written ',istep1,time,time_forc

      end subroutine final_restart

!=======================================================================

! Defines a restart field
! author David A Bailey, NCAR

      subroutine define_rest_field(File, vname, dims)

      type(file_desc_t)      , intent(in)  :: File
      character (len=*)      , intent(in)  :: vname
      integer (kind=int_kind), intent(in)  :: dims(:)

      integer (kind=int_kind) :: &
        status        ! status variable from netCDF routine

      status = pio_def_var(File,trim(vname),pio_double,dims,vardesc)
        
      end subroutine define_rest_field

!=======================================================================

      end module ice_restart

!=======================================================================
